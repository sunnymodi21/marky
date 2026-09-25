import AppKit
import Foundation
@testable import Marky
import Testing

private func field(
    id: String = "ax_1",
    role: String = "AXTextField",
    accessibleLabel: String? = nil,
    semanticGroup: String? = nil,
    title: String? = nil,
    placeholder: String? = nil,
    nearby: [String] = [],
    caption: String? = nil,
    part: FieldPart? = nil,
    width: Double? = nil) -> FormFieldSnapshot
{
    FormFieldSnapshot(
        id: id,
        role: role,
        accessibleLabel: accessibleLabel,
        semanticGroup: semanticGroup,
        title: title,
        description: nil,
        help: nil,
        placeholder: placeholder,
        nearbyText: nearby,
        identifier: nil,
        caption: caption,
        part: part,
        width: width)
}

@Suite struct FieldContextBuilderTests {
    @Test func buildsDescriptionFromAccessibilityMetadata() {
        let description = FieldContextBuilder.description(for: field(
            id: "ax_105",
            title: "Work Email",
            placeholder: "name@company.com",
            nearby: ["Primary contact details"]))
        #expect(description.contains("form field labeled \"Work Email\"."))
        #expect(description.contains("Placeholder: \"name@company.com\"."))
        #expect(description.contains("Nearby text: \"Primary contact details\"."))
    }

    @Test func descriptionsKeepFieldContext() {
        let fields = [
            field(id: "ax_1", title: "First Name", placeholder: "Given name"),
            field(id: "ax_4", title: "Business Email", placeholder: "name@company.com"),
        ]
        #expect(fields.map(\.id) == ["ax_1", "ax_4"])
        #expect(FieldContextBuilder.description(for: fields[0]).contains("form field labeled \"First Name\"."))
    }

    @Test func accessibleLabelTakesPrecedenceOverGenericAXMetadata() {
        let description = FieldContextBuilder.description(for: field(
            accessibleLabel: "Current job title",
            semanticGroup: "Employment history",
            title: "text field",
            placeholder: "Role",
            nearby: ["Unrelated nearby field"]))

        #expect(description.hasPrefix(
            "Employment history Current job title."))
        #expect(!description.contains("text field"))
        #expect(!description.contains("Unrelated nearby field"))
        #expect(description.contains("Placeholder: \"Role\"."))
    }

    @Test func buildsSemanticSchemaNamesWithoutFormSpecificRules() {
        let grouped = FieldContextBuilder.schema(for: field(
            accessibleLabel: "Full Name",
            semanticGroup: "Emergency contact"))
        let ungrouped = FieldContextBuilder.schema(for: field(accessibleLabel: "Work E-mail"))

        #expect(grouped["group"] == "emergency_contact")
        #expect(grouped["name"] == "full_name")
        #expect(ungrouped["group"] == "current_form")
        #expect(ungrouped["name"] == "work_e_mail")
    }

    @Test func captionLabelsFieldsWithoutAnAccessibleName() {
        // RoboForm-style column: plain-text captions above unnamed inputs.
        let column = ["First Name", "Address 1", "City", "Company Name"]
        let fields = column.enumerated().map { index, caption in
            field(id: "ax_\(index + 1)", nearby: column, caption: caption)
        }
        let schemas = fields.map(FieldContextBuilder.schema(for:))

        #expect(schemas.map { $0["name"] } == ["first_name", "address_1", "city", "company_name"])
        #expect(schemas[0]["description"] == "Value for the form field labeled \"First Name\".")
        #expect(schemas.allSatisfy { !$0["description"]!.contains("Nearby text") })
    }

    @Test func splitBoxesExtractOnceAndFillEachChunk() {
        let fields = [
            field(id: "ax_1", caption: "Home Phone Number", part: .init(leadID: "ax_1", index: 0, count: 3)),
            field(id: "ax_2", caption: "Home Phone Number", part: .init(leadID: "ax_1", index: 1, count: 3)),
            field(id: "ax_3", caption: "Home Phone Number", part: .init(leadID: "ax_1", index: 2, count: 3)),
            field(id: "ax_4", caption: "Postal Code"),
        ]
        #expect(FieldContextBuilder.extractionFields(fields).map(\.id) == ["ax_1", "ax_4"])

        let filled = Dictionary(uniqueKeysWithValues: FieldContextBuilder.assignments(fields: fields, extracted: [
            .init(fieldID: "ax_1", value: "+1 (721) 536-3224", confidence: 0.9),
            .init(fieldID: "ax_4", value: "94105", confidence: 0.9),
        ]))
        #expect(filled == ["ax_1": "721", "ax_2": "536", "ax_3": "3224", "ax_4": "94105"])
    }

    @Test func splitBoxesStayEmptyWhenTheValueDoesNotFitTheLayout() {
        let fields = (0..<3).map { index in
            field(id: "ax_\(index + 1)", caption: "Phone", part: .init(leadID: "ax_1", index: index, count: 3))
        }
        let filled = FieldContextBuilder.assignments(fields: fields, extracted: [
            .init(fieldID: "ax_1", value: "536-3224", confidence: 0.9),
        ])
        #expect(filled.isEmpty)
    }

    @Test func splitsFollowTheValueSeparatorsOrTheBoxWidths() {
        let two: [Double?] = [nil, nil]
        #expect(SplitFieldValue.split("94105-1234", widths: two) == ["94105", "1234"])
        #expect(SplitFieldValue.split("03/2027", widths: two) == ["03", "2027"])
        #expect(SplitFieldValue.split("Jennifer Woods", widths: two) == ["Jennifer", "Woods"])
        #expect(SplitFieldValue.split("Mary Ann Smith", widths: two) == nil)
        #expect(SplitFieldValue.split("+44 20 7946 0958", widths: [nil, nil, nil]) == ["20", "7946", "0958"])
        // Unbroken run: 3/3/4 digits from box widths, no layout table.
        #expect(SplitFieldValue.split("4155550142", widths: [31, 31, 38]) == ["415", "555", "0142"])
        #expect(SplitFieldValue.split("4155550142", widths: [31, nil, 38]) == nil)
    }

    @Test func singleLineFieldsNeverReceiveLineBreaks() {
        let fields = [
            field(id: "ax_1", caption: "Address 1"),
            field(id: "ax_2", role: "AXTextArea", caption: "Notes"),
        ]
        let filled = Dictionary(uniqueKeysWithValues: FieldContextBuilder.assignments(fields: fields, extracted: [
            .init(fieldID: "ax_1", value: "1450 Market Street\nSuite 300", confidence: 0.99),
            .init(fieldID: "ax_2", value: "Leave at door\nRing twice", confidence: 0.99),
        ]))
        #expect(filled["ax_1"] == "1450 Market Street, Suite 300")
        #expect(filled["ax_2"] == "Leave at door\nRing twice")
    }

    @Test func fillsHighConfidenceEmptyFieldsAndSkipsTheRest() {
        let fields = [
            field(id: "ax_1", title: "First Name"),
            field(id: "ax_2", title: "Last Name"),
            field(id: "ax_3", title: "Department"),
            field(id: "ax_5", title: "Password"),
        ]
        let extracted: [ExtractedFieldValue] = [
            .init(fieldID: "ax_1", value: "Jennifer", confidence: 0.95),
            .init(fieldID: "ax_2", value: "Woods", confidence: 0.93),
            .init(fieldID: "ax_3", value: "QA", confidence: 0.40),
            .init(fieldID: "ax_5", value: "hunter2", confidence: 0.99),
        ]
        let filled = Dictionary(
            uniqueKeysWithValues: FieldContextBuilder.assignments(fields: fields, extracted: extracted))
        #expect(filled["ax_1"] == "Jennifer")
        #expect(filled["ax_2"] == "Woods")
        #expect(filled["ax_3"] == nil)
        #expect(filled["ax_5"] == nil)
    }
}

@Suite struct SensitiveFieldDetectorTests {
    @Test func treatsPasswordAndPaymentFieldsAsSensitive() {
        #expect(SensitiveFieldDetector.isSensitive(field(role: "AXSecureTextField", title: "User")))
        #expect(SensitiveFieldDetector.isSensitive(field(title: "Password")))
        #expect(SensitiveFieldDetector.isSensitive(field(accessibleLabel: "Password")))
        #expect(SensitiveFieldDetector.isSensitive(field(title: "Credit card number")))
        #expect(SensitiveFieldDetector.isSensitive(field(placeholder: "CVV")))
        #expect(SensitiveFieldDetector.isSensitive(field(title: "Social Security Number")))
        #expect(!SensitiveFieldDetector.isSensitive(field(title: "Work Email")))
        #expect(!SensitiveFieldDetector.isSensitive(field(title: "Account name")))
    }

    @Test func captionReplacesSiblingTextForSensitivity() {
        let siblings = ["Enter your Email Address", "Choose A Password", "Hint (Optional)"]
        #expect(!SensitiveFieldDetector.isSensitive(field(nearby: siblings, caption: "Enter your Email Address")))
        #expect(SensitiveFieldDetector.isSensitive(field(nearby: siblings)))
        #expect(SensitiveFieldDetector.isSensitive(field(caption: "Credit Card Number")))
    }
}

@Suite struct GLiNERWorkerResponseTests {
    @Test func modelUsesVersionedMarkyDownloadURL() {
        #expect(GLiNERService.modelBaseURL.host == "download.marky.click")
        #expect(GLiNERService.modelBaseURL.path.contains(GLiNERService.modelRevision))
    }

    @Test func workerScriptIsPresent() {
        #expect(GLiNERService.workerScriptURL() != nil)
    }

    @Test func parsesNormalizedWorkerValues() throws {
        let json = """
        {"id": 3, "ok": true, "values": [
          {"fieldID": "ax_1", "value": "Jennifer", "confidence": 0.95},
          {"fieldID": "ax_2", "value": "   ", "confidence": 0.99}
        ]}
        """.data(using: .utf8)!
        let response = try GLiNERWorkerResponse.decode(json)
        #expect(response.ok)
        #expect(response.values.map(\.fieldID) == ["ax_1"])
        #expect(response.values[0].value == "Jennifer")
    }
}

@MainActor
@Suite struct ClipboardReaderTests {
    @Test func readsPlainTextAndRejectsEmptyOrConfidential() throws {
        let pasteboard = NSPasteboard(name: .init("marky-smartfill-\(UUID().uuidString)"))
        let service = PasteboardService(pasteboard: pasteboard)
        let suite = "marky-smartfill-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let policy = ClipboardPolicy(settings: AppSettings(defaults: defaults), frontmostBundleID: { nil })

        pasteboard.clearContents()
        #expect(throws: SmartFillError.emptyClipboard) {
            try ClipboardReader.readText(from: service, policy: policy)
        }

        pasteboard.clearContents()
        pasteboard.setString("Jennifer Woods", forType: .string)
        #expect(try ClipboardReader.readText(from: service, policy: policy) == "Jennifer Woods")

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        #expect(throws: SmartFillError.confidentialClipboard) {
            try ClipboardReader.readText(from: service, policy: policy)
        }
    }
}
