import Foundation
@testable import Marky
import Testing

/// RoboForm's public filling-test pages: plain-text captions with no
/// `<label for>`, laid out above the box, in a cell to its left, and around
/// split phone boxes.
private func scan(_ page: String) throws -> [FormFieldSnapshot] {
    let url = try #require(Bundle.module.url(
        forResource: "roboform-\(page)", withExtension: "html", subdirectory: "Fixtures/SmartFill"))
    let window = try ChromeLikeTree.window(html: Data(contentsOf: url))
    return FormTreeScanner.scan(window: window).map(\.snapshot)
}

@Suite struct FormTreeScannerFixtureTests {
    @Test func captionsInTheCellLeftOfEachBox() throws {
        let fields = try scan("all-fields")
        #expect(fields.map(\.caption) == [
            "Title", "First Name", "Middle Initial", "Last Name", "Full Name", "Company", "Position",
            "Address Line 1", "Address Line 2", "City", "State / Province", "Country", "Zip",
            "Home Phone", "Work Telephone", "Fax", "Cell Phone", "E-mail", "Web Site", "User ID",
            "Password", "Credit Card Number", "Card Verification Code", "Card User Name",
            "Card Issuing Bank", "Card Customer Service Phone", "Sex", "Social Security Number",
            "Driver License Number", "Age", "Birth Place", "Income", "Custom Message", "Comments",
        ])
        #expect(fields.allSatisfy { $0.semanticGroup == nil && $0.part == nil })
        #expect(fields.filter(SensitiveFieldDetector.isSensitive).map(\.caption) == [
            "Password", "Credit Card Number", "Card Verification Code", "Social Security Number",
        ])
    }

    @Test func customFieldsSkipChoiceControlsAndImageCaptions() throws {
        let fields = try scan("custom-fields")
        // The select before the image-captioned box consumes the preceding
        // caption, so that box is left without one rather than mislabeled.
        #expect(fields.map(\.caption) == [
            "Message", "Comments", "Your Comments", "Say It Here", "Resume", nil, "My ID",
        ])
        #expect(fields[4].role == "AXTextArea")
    }

    @Test func shoppingCartCaptionsAboveBoxesAndSplitPhones() throws {
        let fields = try scan("shopping-cart")
        #expect(fields.map(\.caption) == [
            "First Name", "Address 1", "City", "Company Name", "Last Name", "Address 2",
            "Company Phone", "Company Phone", "Company Phone", "Ext:",
            "Home Phone Number", "Home Phone Number", "Home Phone Number", "Postal Code",
            "Fax Number", "Fax Number", "Fax Number",
            "Name on Credit Card or Check", "Credit Card Number", "Enter your Email Address",
            "Choose A Password", "Hint (Optional)", "Verify Your Password",
        ])
        // A column's first caption is not a legend for the whole column.
        #expect(fields.allSatisfy { $0.semanticGroup == nil })
        let home = fields.filter { $0.caption == "Home Phone Number" }
        #expect(home.map(\.part) == (0..<3).map { FieldPart(leadID: home[0].id, index: $0, count: 3) })
        #expect(fields.first { $0.caption == "Enter your Email Address" }.map(SensitiveFieldDetector.isSensitive) == false)
    }

    @Test func explicitLabelsStillWinOverCaptions() throws {
        let html = """
        <form><div>Shipping</div>
        <label for="a">Recipient</label><input id="a" type="text">
        <div>Unrelated caption</div><input type="text" aria-label="Gift message">
        </form>
        """
        let window = try ChromeLikeTree.window(html: Data(html.utf8))
        let fields = FormTreeScanner.scan(window: window).map(\.snapshot)
        #expect(fields.map(\.accessibleLabel) == ["Recipient", "Gift message"])
        #expect(fields.map(\.caption) == [nil, nil])
    }
}

/// Runs each fixture page through the installed GLiNER model with sample
/// data. Opt-in (needs the model and its Python runtime):
/// `MARKY_GLINER_TESTS=1 swift test --filter SmartFillModelFixtureTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MARKY_GLINER_TESTS"] == "1"))
struct SmartFillModelFixtureTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var page: String
        var clipboard: String
        var expected: [String: String]
        var testDescription: String { self.page }
    }

    static let cases: [Case] = [
        Case(
            page: "all-fields",
            clipboard: """
            Dr. Jennifer R. Woods
            Operations Manager, Acme Logistics
            1450 Market Street, Suite 300
            San Francisco, California 94105, United States
            Home: (415) 555-0142 · Work: (415) 555-0199 · Fax: (415) 555-0177 · Cell: (415) 555-0110
            jennifer.woods@example.com · https://acme.example.com
            Username: jwoods · Age 38 · Born in Portland, Oregon
            """,
            expected: [
                "First Name": "Jennifer", "Last Name": "Woods", "Company": "Acme Logistics",
                "Position": "Operations Manager", "City": "San Francisco", "Zip": "94105",
                "Home Phone": "(415) 555-0142", "Cell Phone": "(415) 555-0110",
                "E-mail": "jennifer.woods@example.com",
            ]),
        Case(
            page: "custom-fields",
            clipboard: """
            Message: Please ship before Friday.
            My ID: JW-2044
            Resume: Ten years in logistics operations.
            """,
            expected: ["Message": "Please ship before Friday", "My ID": "JW-2044"]),
        Case(
            page: "shopping-cart",
            clipboard: """
            Jennifer Woods
            Acme Logistics
            1450 Market Street
            Suite 300
            San Francisco, CA 94105
            Home: (415) 555-0142
            Work: (415) 555-0199 ext. 214
            Fax: (415) 555-0177
            jennifer.woods@example.com
            """,
            expected: [
                "First Name": "Jennifer", "Last Name": "Woods", "City": "San Francisco",
                "Company Name": "Acme Logistics", "Postal Code": "94105",
                "Enter your Email Address": "jennifer.woods@example.com",
                "Home Phone Number": "415|555|0142", "Fax Number": "415|555|0177",
            ]),
    ]

    @Test(arguments: Self.cases) func fillsFromSampleData(_ testCase: Case) throws {
        let fields = try scan(testCase.page).filter { !SensitiveFieldDetector.isSensitive($0) }
        let extracted = try Self.extract(testCase.clipboard, FieldContextBuilder.extractionFields(fields))
        let filled = Dictionary(uniqueKeysWithValues: FieldContextBuilder.assignments(fields: fields, extracted: extracted))

        // Caption → value, with split parts joined by "|".
        var byCaption: [String: [String]] = [:]
        for field in fields {
            guard let caption = field.caption, let value = filled[field.id] else { continue }
            byCaption[caption, default: []].append(value)
        }
        let actual = byCaption.mapValues { $0.joined(separator: "|") }
        print("[\(testCase.page)] filled \(filled.count)/\(fields.count): "
            + actual.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        for (caption, value) in testCase.expected {
            #expect(actual[caption] == value, "\(testCase.page): \(caption)")
        }
    }

    private static func extract(_ text: String, _ fields: [FormFieldSnapshot]) throws -> [ExtractedFieldValue] {
        let environment = ProcessInfo.processInfo.environment
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Marky/gliner")
        let models = support.appendingPathComponent("models")
        let model = try #require(try FileManager.default.contentsOfDirectory(atPath: models.path)
            .first { !$0.hasPrefix(".") }
            .map { models.appendingPathComponent($0) })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["MARKY_GLINER_PYTHON"]
            ?? "/Applications/Marky.app/Contents/Resources/python/bin/python3")
        process.arguments = [try #require(GLiNERService.workerScriptURL()).path]
        process.environment = [
            "MARKY_GLINER_MODEL": model.path,
            "HF_HOME": support.appendingPathComponent("hub").path,
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "PYTHONUNBUFFERED": "1",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let request: [String: Any] = [
            "id": 1,
            "op": "extract",
            "text": text,
            "minimumConfidence": FieldContextBuilder.minimumConfidence,
            "fields": fields.map { FieldContextBuilder.schema(for: $0) },
        ]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reply = try #require(data.split(separator: 0x0A).last)
        return try GLiNERWorkerResponse.decode(Data(reply)).values
    }
}
