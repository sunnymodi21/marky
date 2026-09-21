import ApplicationServices
import Foundation

struct FormField {
    let element: AXUIElement
    let snapshot: FormFieldSnapshot
}

struct FormFieldSnapshot: Sendable, Equatable {
    var id: String
    var role: String?
    var title: String?
    var description: String?
    var help: String?
    var placeholder: String?
    var nearbyText: [String]
    var identifier: String?
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
        if let role = field.role {
            parts.append("Form control type: \(role).")
        }
        if let title = Self.cleaned(field.title) {
            parts.append("Label: \"\(title)\".")
        }
        if let description = Self.cleaned(field.description), description != Self.cleaned(field.title) {
            parts.append("Description: \"\(description)\".")
        }
        if let help = Self.cleaned(field.help) {
            parts.append("Help: \"\(help)\".")
        }
        if let placeholder = Self.cleaned(field.placeholder) {
            parts.append("Placeholder: \"\(placeholder)\".")
        }
        let nearby = field.nearbyText.compactMap(Self.cleaned)
        if !nearby.isEmpty {
            parts.append("Nearby text: \(nearby.map { "\"\($0)\"" }.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    /// Values Smart Fill should write. Skips empties, low-confidence matches,
    /// and sensitive fields.
    static func assignments(
        fields: [FormFieldSnapshot],
        extracted: [ExtractedFieldValue]) -> [(fieldID: String, value: String)]
    {
        let values = Dictionary(extracted.map { ($0.fieldID, $0) }, uniquingKeysWith: { _, latest in latest })
        return fields.compactMap { field in
            guard let extracted = values[field.id] else { return nil }
            let value = extracted.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  extracted.confidence >= Self.minimumConfidence,
                  !SensitiveFieldDetector.isSensitive(field)
            else { return nil }
            return (field.id, value)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.ellipsized(limit: 160)
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
        let haystack = ([
            field.title,
            field.description,
            field.help,
            field.placeholder,
            field.identifier,
        ] + field.nearbyText)
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
