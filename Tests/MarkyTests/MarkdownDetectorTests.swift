import MarkyCore
import Testing

@Suite struct MarkdownDetectorTests {
    let detector = MarkdownDetector()

    @Test func detectsTypicalLLMAnswer() {
        let text = """
        # Status update

        **Done:** shipped the *parser*.

        - Fixed [the bug](https://example.com)
        - Added tests
        """
        #expect(self.detector.isMarkdown(text))
    }

    @Test func headingAloneIsNotEnough() {
        // A lone heading scores below the fixed threshold; avoids false positives
        // on shell comments and prose starting with '#'.
        let text = "# Release notes\nsome plain text below"
        #expect(!self.detector.isMarkdown(text))
    }

    @Test func detectsTable() {
        let text = """
        | Name | Value |
        |------|-------|
        | a    | 1     |
        | b    | 2     |
        """
        #expect(self.detector.isMarkdown(text))
    }

    @Test func detectsFencedCodeWithProse() {
        let text = """
        Run the build:

        ```sh
        make all
        ```

        Then **verify** the output.
        """
        #expect(self.detector.isMarkdown(text))
    }

    @Test func rejectsPlainProse() {
        let text = """
        Hello team, just a quick note that the meeting moved to 3pm.
        Please update your calendars accordingly. Thanks!
        """
        #expect(!self.detector.isMarkdown(text))
    }

    @Test func rejectsShellCommands() {
        let multiline = """
        kubectl get pods \\
          -n kube-system \\
          | jq '.items[].metadata.name'
        """
        #expect(self.detector.score(multiline) == 0)

        let simple = "brew install --cask some/tap/sometool"
        #expect(self.detector.score(simple) == 0)
    }

    @Test func rejectsBareURL() {
        #expect(self.detector.score("https://example.com/some/path?q=1") == 0)
    }

    @Test func rejectsSourceCode() {
        let code = """
        func add(a: Int, b: Int) -> Int {
            return a + b
        }
        """
        #expect(self.detector.score(code) == 0)
    }

    @Test func rejectsEmpty() {
        #expect(self.detector.score("") == 0)
        #expect(self.detector.score("   \n  ") == 0)
    }

    @Test func sizeSafetyValve() {
        let huge = Array(repeating: "- list item with **bold**", count: 500).joined(separator: "\n")
        #expect(self.detector.score(huge) == 0)
        let smaller = Array(repeating: "- list item with **bold**", count: 50).joined(separator: "\n")
        #expect(self.detector.score(smaller) > 0)
    }

    @Test func taskListAndStrikethroughScore() {
        let text = """
        - [x] done item
        - [ ] open item with ~~strikethrough~~
        """
        #expect(self.detector.score(text) >= 3)
    }
}
