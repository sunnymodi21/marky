import Foundation

/// Score-based Markdown detection.
///
/// Positive cues add to a score; negative gates reject outright (shell commands,
/// source code, bare URLs). The score is compared against the config's threshold.
public struct MarkdownDetector: Sendable {
    private static let knownCommandPrefixes: Set<String> = [
        "sudo", "./", "~/", "apt", "brew", "git", "python", "pip", "pnpm", "npm", "yarn", "cargo",
        "bundle", "rails", "go", "make", "xcodebuild", "swift", "kubectl", "docker", "podman", "aws",
        "gcloud", "az", "ls", "cd", "cat", "echo", "env", "export", "open", "node", "java", "ruby",
        "perl", "bash", "zsh", "fish", "pwsh", "sh", "curl", "wget", "ssh", "rsync", "tar", "grep",
        "rg", "find", "chmod", "chown", "mkdir", "rm", "cp", "mv", "pbpaste", "pbcopy",
    ]

    public init() {}

    public func isMarkdown(_ text: String, config: ConvertConfig = ConvertConfig()) -> Bool {
        self.score(text, config: config) >= config.scoreThreshold
    }

    /// Returns 0 when a negative gate rejects the text outright.
    public func score(_ text: String, config: ConvertConfig = ConvertConfig()) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let lines = trimmed.split(
            maxSplits: config.maxLines,
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline)
        guard lines.count <= config.maxLines else { return 0 }

        if self.isBareURL(trimmed) { return 0 }

        let hasBold = self.hasBold(trimmed)
        let hasLink = self.hasLink(trimmed)
        let hasTable = self.hasTable(lines)
        if self.looksLikeShellCommand(
            lines: lines,
            hasUnambiguousMarkdownCue: hasBold || hasLink || hasTable)
        {
            return 0
        }

        var score = 0

        // Strong cues (2 points each)
        if self.hasFencedCodeBlock(lines) { score += 2 }
        if self.hasATXHeading(lines) { score += 2 }
        if hasLink { score += 2 }
        // A pipe table with a separator row is unambiguous markdown.
        if hasTable { score += 3 }
        if hasBold { score += 2 }

        // Moderate cues (1 point each)
        if self.hasList(lines) { score += 1 }
        if self.hasBlockquote(lines) { score += 1 }
        if self.hasInlineCode(trimmed) { score += 1 }
        if self.hasItalic(trimmed) { score += 1 }
        if self.hasStrikethrough(trimmed) { score += 1 }
        if self.hasTaskList(lines) { score += 1 }

        // Source code without any structural markdown cues: reject.
        if score < 4, self.looksLikeSourceCode(trimmed) { return 0 }

        return score
    }

    // MARK: - Positive cues

    private func hasATXHeading(_ lines: [Substring]) -> Bool {
        lines.contains { line in
            line.range(of: #"^#{1,6} \S"#, options: .regularExpression) != nil
        }
    }

    private func hasBold(_ text: String) -> Bool {
        text.range(of: #"\*\*[^*\n]+\*\*"#, options: .regularExpression) != nil
            || text.range(of: #"__[^_\n]+__"#, options: .regularExpression) != nil
    }

    private func hasItalic(_ text: String) -> Bool {
        // Single asterisk/underscore emphasis; avoid matching ** pairs or snake_case.
        text.range(of: #"(?<![*\w])\*[^*\n]+\*(?![*\w])"#, options: .regularExpression) != nil
            || text.range(of: #"(?<![\w_])_[^_\n]+_(?![\w_])"#, options: .regularExpression) != nil
    }

    private func hasStrikethrough(_ text: String) -> Bool {
        text.range(of: #"~~[^~\n]+~~"#, options: .regularExpression) != nil
    }

    private func hasLink(_ text: String) -> Bool {
        text.range(of: #"!?\[[^\]\n]+\]\([^)\n]+\)"#, options: .regularExpression) != nil
    }

    private func hasInlineCode(_ text: String) -> Bool {
        text.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil
    }

    private func hasFencedCodeBlock(_ lines: [Substring]) -> Bool {
        let fenceCount = lines.count { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        return fenceCount >= 2
    }

    private func hasList(_ lines: [Substring]) -> Bool {
        let listLines = lines.count { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.range(of: #"^[-*+] \S"#, options: .regularExpression) != nil
                || t.range(of: #"^\d{1,3}[.)] \S"#, options: .regularExpression) != nil
        }
        return listLines >= 2
    }

    private func hasTaskList(_ lines: [Substring]) -> Bool {
        lines.contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil
        }
    }

    private func hasBlockquote(_ lines: [Substring]) -> Bool {
        lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("> ") }
    }

    private func hasTable(_ lines: [Substring]) -> Bool {
        // Require a header-separator row (|---|---|) adjacent to a pipe row.
        for (index, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.range(of: #"^\|?[\s:|-]+\|[\s:|-]+\|?$"#, options: .regularExpression) != nil,
                  t.contains("-")
            else { continue }
            if index > 0, lines[index - 1].contains("|") { return true }
        }
        return false
    }

    // MARK: - Negative gates

    private func isBareURL(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        return text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
    }

    private func looksLikeShellCommand(
        lines: [Substring],
        hasUnambiguousMarkdownCue: Bool) -> Bool
    {
        // Unambiguous Markdown cues disqualify the shell-command gate. Headings
        // remain ambiguous with comments and prompts.
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return false }

        if hasUnambiguousMarkdownCue { return false }

        let commandish = nonEmpty.count { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("$ ") { return true }
            if t.contains("\\") && t.hasSuffix("\\") { return true }
            guard let firstToken = t.split(separator: " ").first?.lowercased() else { return false }
            guard Self.knownCommandPrefixes.contains(firstToken)
                    || Self.knownCommandPrefixes.contains(where: { firstToken.hasPrefix($0 + "/") })
            else { return false }
            // `git` alone could be prose ("git is great."); require flags/paths/pipes.
            return t.range(of: #"(\s--?[A-Za-z]|[|><]|/)"#, options: .regularExpression) != nil
                || t.split(separator: " ").count >= 2
        }
        return commandish == nonEmpty.count
    }

    private func looksLikeSourceCode(_ text: String) -> Bool {
        let hasBraces = text.contains("{") || text.contains("}")
        let keywordPattern =
            #"(?m)^\s*(import|package|namespace|using|template|class|struct|enum|extension|protocol|"#
                + #"interface|func|def|fn|let|var|const|public|private|internal|return|if|for|while)\b"#
        let hasKeywords = text.range(of: keywordPattern, options: .regularExpression) != nil
        return hasBraces && hasKeywords
    }
}
