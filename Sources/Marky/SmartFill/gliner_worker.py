#!/usr/bin/env python3
"""Local GLiNER2.5 worker for Marky Smart Fill.

Reads one JSON object per stdin line, writes one JSON object per stdout line.

Protocol:
  {"id": 1, "op": "load"}
  {"id": 1, "op": "extract", "text": "...", "minimumConfidence": 0.65,
   "fields":
    [{"id": "ax_1", "group": "personal", "name": "full_name",
      "description": "Personal Full Name."}]}

The form fields are the extraction schema. There is no generic-entity pass.
"""

from __future__ import annotations

import json
import os
import re
import sys
import traceback
from typing import Any


MODEL_ID = os.environ.get("MARKY_GLINER_MODEL", "fastino/gliner2.5-base-v1")
EXTRACTOR = None


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def reply(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def load_model() -> None:
    global EXTRACTOR
    if EXTRACTOR is not None:
        return

    from gliner2 import AutoExtractor

    map_location = "cpu"
    try:
        import torch

        if torch.backends.mps.is_available():
            map_location = "mps"
    except Exception:
        map_location = "cpu"

    log(f"loading {MODEL_ID} on {map_location}")
    try:
        EXTRACTOR = AutoExtractor.from_pretrained(MODEL_ID, map_location=map_location)
    except Exception:
        if map_location != "cpu":
            log("mps load failed; retrying on cpu")
            EXTRACTOR = AutoExtractor.from_pretrained(MODEL_ID, map_location="cpu")
        else:
            raise
    log("model ready")


def normalize_field_value(raw: Any) -> tuple[str, float | None] | None:
    """Return (text, confidence) or None if there is no meaningful value."""
    if raw is None:
        return None
    if isinstance(raw, str):
        text = raw.strip()
        return (text, None) if text else None
    if isinstance(raw, dict):
        text = str(raw.get("text") or raw.get("value") or "").strip()
        if not text:
            return None
        confidence = raw.get("confidence")
        try:
            conf = float(confidence) if confidence is not None else None
        except (TypeError, ValueError):
            conf = None
        return (text, conf)
    if isinstance(raw, (list, tuple)):
        best: tuple[str, float | None] | None = None
        best_conf = -1.0
        for item in raw:
            normalized = normalize_field_value(item)
            if normalized is None:
                continue
            text, conf = normalized
            score = conf if conf is not None else 0.0
            if best is None or score > best_conf:
                best = (text, conf)
                best_conf = score
        return best
    text = str(raw).strip()
    return (text, None) if text else None


def structure_instances(result: Any, structure_name: str) -> list[Any]:
    if not isinstance(result, dict):
        return []
    structure = result.get(structure_name)
    if isinstance(structure, list):
        return structure
    if isinstance(structure, dict):
        return [structure]
    return []


def schema_key(raw: Any, fallback: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "_", str(raw or "").strip().lower())
    return value.strip("_") or fallback


def map_fields(
    fields: list[dict[str, Any]],
) -> tuple[dict[str, dict[str, str]], dict[tuple[str, str], str | None]]:
    field_maps: dict[str, dict[str, str]] = {}
    descriptions: dict[tuple[str, str], str | None] = {}
    for field in fields:
        field_id = str(field.get("id") or "").strip()
        if not field_id:
            continue
        structure_name = schema_key(field.get("group"), "current_form")
        base_name = schema_key(field.get("name"), field_id)
        field_map = field_maps.setdefault(structure_name, {})
        schema_name = base_name
        suffix = 2
        while schema_name in field_map:
            schema_name = f"{base_name}_{suffix}"
            suffix += 1
        description = str(field.get("description") or "").strip()
        field_map[schema_name] = field_id
        descriptions[(structure_name, schema_name)] = description or None
    return field_maps, descriptions


def build_schema(
    field_maps: dict[str, dict[str, str]],
    descriptions: dict[tuple[str, str], str | None],
    anchors_only: bool = False,
) -> Any:
    schema = EXTRACTOR.create_schema()
    for structure_name, field_map in field_maps.items():
        names = list(field_map)
        if anchors_only:
            names = names[:1]
            builder = schema.structure(
                structure_name, mode="natural", anchor=names[0]
            )
        else:
            builder = schema.structure(structure_name)
        for schema_name in names:
            builder.field(
                schema_name,
                dtype="str",
                description=descriptions[(structure_name, schema_name)],
            )
    return schema


def values_from_structures(
    result: Any, field_maps: dict[str, dict[str, str]]
) -> dict[str, tuple[str, float]]:
    """Flatten grouped GLiNER output into AX field ID → value rows."""
    best: dict[str, tuple[str, float]] = {}

    for structure_name, field_map in field_maps.items():
        for instance in structure_instances(result, structure_name):
            if not isinstance(instance, dict):
                continue
            for schema_name, field_id in field_map.items():
                if schema_name not in instance:
                    continue
                normalized = normalize_field_value(instance.get(schema_name))
                if normalized is None:
                    continue
                text, conf = normalized
                score = conf if conf is not None else 0.75
                previous = best.get(field_id)
                if previous is None or score >= previous[1]:
                    best[field_id] = (text, score)
    return best


def apply_anchor_disambiguation(
    best: dict[str, tuple[str, float]],
    anchor_result: Any,
    field_maps: dict[str, dict[str, str]],
    minimum_confidence: float,
) -> None:
    """Keep grouped records from being mixed together.

    Natural-mode anchors are returned in document order. When a group has
    multiple distinct anchors, the source describes repeated records. Preserve
    a structured match when its sibling values form an equally confident
    record; otherwise keep only the first anchor rather than mixing records.
    """
    for structure_name, field_map in field_maps.items():
        if not field_map:
            continue
        anchor_name, anchor_id = next(iter(field_map.items()))
        candidates: list[tuple[str, float]] = []
        seen: set[str] = set()
        for instance in structure_instances(anchor_result, structure_name):
            if not isinstance(instance, dict):
                continue
            normalized = normalize_field_value(instance.get(anchor_name))
            if normalized is None:
                continue
            text, conf = normalized
            score = conf if conf is not None else 0.75
            if score < minimum_confidence:
                continue
            key = text.casefold()
            if key in seen:
                continue
            seen.add(key)
            candidates.append((text, score))

        if len(candidates) <= 1:
            continue
        current_anchor = best.get(anchor_id)
        if (
            current_anchor is not None
            and current_anchor[0].strip().casefold()
            == candidates[0][0].strip().casefold()
        ):
            continue
        if current_anchor is not None:
            sibling_scores = [
                best[field_id][1]
                for field_id in field_map.values()
                if field_id != anchor_id and field_id in best
            ]
            if sibling_scores and min(sibling_scores) >= candidates[0][1]:
                continue
        for field_id in field_map.values():
            best.pop(field_id, None)
        best[anchor_id] = candidates[0]


def extract(
    text: str,
    fields: list[dict[str, Any]],
    minimum_confidence: float,
) -> list[dict[str, Any]]:
    if EXTRACTOR is None:
        raise RuntimeError("model is not loaded")

    field_maps, descriptions = map_fields(fields)

    if not field_maps:
        return []

    schema = build_schema(field_maps, descriptions)
    result = EXTRACTOR.extract(text, schema, include_confidence=True)
    best = values_from_structures(result, field_maps)

    anchor_schema = build_schema(field_maps, descriptions, anchors_only=True)
    anchor_result = EXTRACTOR.extract(
        text, anchor_schema, include_confidence=True
    )
    apply_anchor_disambiguation(
        best, anchor_result, field_maps, minimum_confidence
    )

    return [
        {"fieldID": field_id, "value": value, "confidence": confidence}
        for field_id, (value, confidence) in best.items()
    ]


def handle(request: dict[str, Any]) -> dict[str, Any]:
    request_id = request.get("id")
    op = request.get("op")
    if op == "load":
        load_model()
        return {"id": request_id, "ok": True, "op": "ready", "model": MODEL_ID}
    if op == "extract":
        load_model()
        text = str(request.get("text") or "")
        fields = request.get("fields") or []
        if not isinstance(fields, list):
            raise ValueError("fields must be a list")
        try:
            minimum_confidence = float(request.get("minimumConfidence", 0.0))
        except (TypeError, ValueError):
            minimum_confidence = 0.0
        values = extract(text, fields, minimum_confidence)
        return {"id": request_id, "ok": True, "values": values}
    raise ValueError(f"unknown op: {op!r}")


def main() -> int:
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            reply(handle(request))
        except Exception as exc:
            log(traceback.format_exc())
            reply(
                {
                    "id": request_id,
                    "ok": False,
                    "error": str(exc),
                }
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
