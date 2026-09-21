#!/usr/bin/env python3
"""Local GLiNER2.5 worker for Marky Smart Fill.

Reads one JSON object per stdin line, writes one JSON object per stdout line.

Protocol:
  {"id": 1, "op": "load"}
  {"id": 1, "op": "extract", "text": "...", "fields": [{"id": "ax_1", "description": "..."}]}

The form fields are the extraction schema. There is no generic-entity pass.
"""

from __future__ import annotations

import json
import os
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


def values_from_structure(result: Any, field_ids: list[str]) -> list[dict[str, Any]]:
    """Flatten GLiNER structure output into fieldID → value rows.

    Typical shape: {"current_form": [{ "ax_1": {...}, "ax_2": "Woods" }]}
    Multiple instances are merged by taking the highest-confidence value per field.
    """
    best: dict[str, tuple[str, float]] = {}

    instances: list[Any] = []
    if isinstance(result, dict):
        form = result.get("current_form", result)
        if isinstance(form, list):
            instances = form
        elif isinstance(form, dict):
            instances = [form]
        else:
            instances = []
    elif isinstance(result, list):
        instances = result

    for instance in instances:
        if not isinstance(instance, dict):
            continue
        for field_id in field_ids:
            if field_id not in instance:
                continue
            normalized = normalize_field_value(instance.get(field_id))
            if normalized is None:
                continue
            text, conf = normalized
            score = conf if conf is not None else 0.75
            previous = best.get(field_id)
            if previous is None or score >= previous[1]:
                best[field_id] = (text, score)

    return [
        {"fieldID": field_id, "value": text, "confidence": confidence}
        for field_id, (text, confidence) in best.items()
    ]


def extract(text: str, fields: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if EXTRACTOR is None:
        raise RuntimeError("model is not loaded")

    schema = EXTRACTOR.create_schema()
    builder = schema.structure("current_form")
    field_ids: list[str] = []
    for field in fields:
        field_id = str(field.get("id") or "").strip()
        if not field_id:
            continue
        description = str(field.get("description") or "").strip()
        builder.field(field_id, dtype="str", description=description or None)
        field_ids.append(field_id)

    if not field_ids:
        return []

    result = EXTRACTOR.extract(text, schema, include_confidence=True)
    return values_from_structure(result, field_ids)


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
        values = extract(text, fields)
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
