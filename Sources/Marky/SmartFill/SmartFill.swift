import ApplicationServices
import Foundation

struct FormField {
    let element: AXUIElement
    var snapshot: FormFieldSnapshot
}

struct FormFieldSnapshot: Sendable, Equatable {
    var id: String
    var role: String?
    var accessibleLabel: String?
    var semanticGroup: String?
    var title: String?
    var description: String?
    var help: String?
    var placeholder: String?
    var nearbyText: [String]
    var identifier: String?
    /// Text preceding the field in document order, for pages whose captions
    /// are plain text with no programmatic link to the control.
    var caption: String? = nil
    /// Set when several boxes share one caption (e.g. a split phone number).
    var part: FieldPart? = nil
    /// On-screen width, used to apportion an unbroken value across parts.
    var width: Double? = nil
}

struct FieldPart: Sendable, Equatable {
    /// The first box; only it is sent for extraction.
    var leadID: String
    var index: Int
    var count: Int
}

struct ExtractedFieldValue: Codable, Sendable, Equatable {
    var fieldID: String
    var value: String
    var confidence: Float
}

enum SmartFillError: Error, LocalizedError, Equatable, Sendable {
    case emptyClipboard
    case confidentialClipboard
    case noFrontmostApp
    case accessibilityDenied
    case noFormFields
    case pythonMissing
    case glinerUnavailable(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            "Clipboard is empty. Copy some text first."
        case .confidentialClipboard:
            "Clipboard is marked confidential, so Smart Fill won't use it."
        case .noFrontmostApp:
            "Couldn't find the frontmost app."
        case .accessibilityDenied:
            "Accessibility permission is required to detect and fill form fields."
        case .noFormFields:
            "No empty text fields found in the frontmost window."
        case .pythonMissing:
            "Python 3.10–3.13 is required for local GLiNER2.5 inference. Install Python and try again."
        case let .glinerUnavailable(detail):
            "Couldn't prepare GLiNER2.5. \(detail)"
        case let .extractionFailed(detail):
            "Extraction failed. \(detail)"
        }
    }
}

enum FieldContextBuilder {
    static let minimumConfidence: Float = 0.65

    static func description(for field: FormFieldSnapshot) -> String {
        var parts: [String] = []
        let accessibleLabel = Self.cleaned(field.accessibleLabel)
        let semanticGroup = Self.cleaned(field.semanticGroup)
        let title = Self.cleaned(field.title)
        let fieldDescription = Self.cleaned(field.description)
        let caption = Self.cleaned(field.caption)
        let label = accessibleLabel ?? title ?? fieldDescription ?? caption

        if let semanticGroup, let label {
            parts.append("\(semanticGroup) \(label).")
        } else if let label {
            parts.append("Value for the form field labeled \"\(label)\".")
        } else {
            parts.append("Value for this form field.")
        }
        if accessibleLabel == nil,
           let fieldDescription,
           fieldDescription != label
        {
            parts.append("Description: \"\(fieldDescription)\".")
        }
        if let help = Self.cleaned(field.help) {
            parts.append("Help: \"\(help)\".")
        }
        if let placeholder = Self.cleaned(field.placeholder) {
            parts.append("Placeholder: \"\(placeholder)\".")
        }
        // Sibling text is a last resort: in a column of captioned boxes it
        // lists every caption, making all the fields look alike.
        if accessibleLabel == nil, caption == nil {
            let nearby = field.nearbyText.compactMap(Self.cleaned)
            if !nearby.isEmpty {
                parts.append("Nearby text: \(nearby.map { "\"\($0)\"" }.joined(separator: ", ")).")
            }
        }
        return parts.joined(separator: " ")
    }

    static func schema(for field: FormFieldSnapshot) -> [String: String] {
        let label = Self.cleaned(field.accessibleLabel)
            ?? Self.cleaned(field.title)
            ?? Self.cleaned(field.description)
            ?? Self.cleaned(field.caption)
            ?? Self.cleaned(field.placeholder)
            ?? Self.cleaned(field.identifier)
            ?? field.id
        return [
            "id": field.id,
            "group": Self.cleaned(field.semanticGroup).map(Self.schemaComponent) ?? "current_form",
            "name": Self.schemaComponent(label),
            "description": Self.description(for: field),
        ]
    }

    /// Fields to send to the extractor: split boxes are represented by their
    /// first part, which carries the shared caption.
    static func extractionFields(_ fields: [FormFieldSnapshot]) -> [FormFieldSnapshot] {
        fields.filter { ($0.part?.index ?? 0) == 0 }
    }

    /// Values Smart Fill should write. Skips empties, low-confidence matches,
    /// and sensitive fields. Split boxes get their chunk of the lead's value.
    static func assignments(
        fields: [FormFieldSnapshot],
        extracted: [ExtractedFieldValue]) -> [(fieldID: String, value: String)]
    {
        let values = Dictionary(extracted.map { ($0.fieldID, $0) }, uniquingKeysWith: { _, latest in latest })
        let partWidths = Dictionary(grouping: fields.filter { $0.part != nil }) { $0.part!.leadID }
            .mapValues { parts in parts.sorted { $0.part!.index < $1.part!.index }.map(\.width) }
        return fields.compactMap { field in
            guard let extracted = values[field.part?.leadID ?? field.id] else { return nil }
            var value = extracted.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  extracted.confidence >= Self.minimumConfidence,
                  !SensitiveFieldDetector.isSensitive(field)
            else { return nil }
            if let part = field.part {
                guard let widths = partWidths[part.leadID],
                      let chunks = SplitFieldValue.split(value, widths: widths)
                else { return nil }
                value = chunks[part.index]
            } else if field.role != "AXTextArea" {
                value = Self.singleLine(value)
            }
            return (field.id, value)
        }
    }

    /// Single-line controls drop or mangle line breaks, so a multi-line
    /// extraction (e.g. a street address with a suite line) is joined.
    static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.ellipsized(limit: 160)
    }

    private static func schemaComponent(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: "_")
    }
}

/// Splits one value across boxes that share a caption. Values that don't
/// map cleanly onto the boxes are left unfilled rather than pasting the
/// whole value into each one.
enum SplitFieldValue {
    static func split(_ value: String, widths: [Double?]) -> [String]? {
        let count = widths.count
        guard count > 1 else { return nil }
        var tokens = value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // An international prefix ("+1", "+44") is not part of a local layout.
        if tokens.count == count + 1, value.hasPrefix("+") {
            tokens.removeFirst()
        }
        // The value's own separators line up with the boxes: "(415) 555-0142",
        // "94105-1234", "03/2027", "Jennifer Woods".
        if tokens.count == count { return tokens }
        // One unbroken run ("4155550142"): apportion by relative box width.
        guard tokens.count == 1,
              let run = tokens.first,
              run.count >= count,
              let lengths = Self.lengths(total: run.count, widths: widths)
        else { return nil }
        var rest = Substring(run)
        return lengths.map { length in
            defer { rest = rest.dropFirst(length) }
            return String(rest.prefix(length))
        }
    }

    /// Largest-remainder apportionment; every box gets at least one character.
    private static func lengths(total: Int, widths: [Double?]) -> [Int]? {
        let known = widths.compactMap { $0 }.filter { $0 > 0 }
        guard known.count == widths.count else { return nil }
        let sum = known.reduce(0, +)
        let exact = known.map { Double(total) * $0 / sum }
        var lengths = exact.map { max(1, Int($0)) }
        var remaining = total - lengths.reduce(0, +)
        let byRemainder = exact.indices.sorted { exact[$0] - exact[$0].rounded(.down) > exact[$1] - exact[$1].rounded(.down) }
        for index in byRemainder where remaining > 0 {
            lengths[index] += 1
            remaining -= 1
        }
        return remaining == 0 ? lengths : nil
    }
}

@MainActor
enum ClipboardReader {
    static func readText(from pasteboard: PasteboardService, policy: ClipboardPolicy) throws -> String {
        if policy.isSensitive(types: pasteboard.types) {
            throw SmartFillError.confidentialClipboard
        }
        guard let text = pasteboard.extractPlainText()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { throw SmartFillError.emptyClipboard }
        return text
    }
}

enum SensitiveFieldDetector {
    static func isSensitive(_ field: FormFieldSnapshot) -> Bool {
        if field.role == "AXSecureTextField" {
            return true
        }
        // A caption pins down which text belongs to this field, so sibling
        // text (e.g. the next field's "Password" caption) no longer applies.
        let haystack = ([
            field.accessibleLabel,
            field.semanticGroup,
            field.title,
            field.description,
            field.help,
            field.placeholder,
            field.identifier,
            field.caption,
        ] + (field.caption == nil ? field.nearbyText : []))
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let needles = [
            "password", "passphrase", "passwd",
            "cvv", "cvc", "csc", "security code",
            "credit card", "card number", "debit card",
            "ssn", "social security",
            "bank account", "account number", "routing number", "iban",
            "one-time", "otp", "2fa", "verification code", "authentication code",
        ]
        return needles.contains { haystack.contains($0) }
    }
}
