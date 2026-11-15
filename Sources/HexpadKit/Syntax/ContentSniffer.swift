import Foundation

/// Sniffs file content to guess a language. Returns nil when unsure.
public enum ContentSniffer {
    /// Resolves the language to use for a file. A recognized extension always
    /// wins; the content sniffer only runs for files whose extension maps to
    /// plain text (including unknown extensions). This prevents a modern-language
    /// file from being re-labelled because, say, two `import` lines look Pythonic.
    public static func resolveLanguage(fileName: String, data: Data) -> Language {
        let extLang = Language.fromFileName(fileName)
        guard extLang == .plain else { return extLang }
        return sniffLanguage(data) ?? .plain
    }

    /// Returns a confident Language guess from file data, or nil.
    public static func sniffLanguage(_ data: Data) -> Language? {
        guard let text = String(data: data, encoding: .utf8) else {
            // Try Latin-1 as fallback for non-UTF8
            guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
            return sniff(text)
        }
        return sniff(text)
    }

    private static func sniff(_ text: String) -> Language? {
        // Take first 4 KB to keep it fast
        let sample = String(text.prefix(4096))
        let lines = sample.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        // 1. Shebang line
        if lines[0].hasPrefix("#!") {
            let shebang = lines[0].lowercased()
            if shebang.contains("python") { return .python }
            if shebang.contains("bash") || shebang.contains("sh") { return .shell }
        }

        // 2. XML declaration
        if sample.hasPrefix("<?xml") { return .xml }

        // 3. HTML doctype or html tag
        if sample.hasPrefix("<!DOCTYPE html") || sample.hasPrefix("<html") { return .html }

        // 4. JSON: starts with { and has "key": pattern
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            // Look for "key": pattern in first few lines
            let firstLines = lines.prefix(10).joined(separator: " ")
            if firstLines.contains("\"") && firstLines.contains(":") {
                // More specific: look for "something":  (quote-colon)
                for line in lines.prefix(10) {
                    if line.contains("\":") {
                        return .json
                    }
                }
            }
        }

        // 5. Python: a `def`/`class` header ending in `:` followed by an
        // indented suite. Bare `import`/`def` counts are shared with Swift,
        // Java, Kotlin, C#, etc. and must not be treated as Python signals.
        if looksLikePython(lines) { return .python }

        // 6. TypeScript before JavaScript: interface, type aliases, enums,
        // and lowercase primitive annotations are TS-only markers.
        if looksLikeTypeScript(sample, lines: lines) { return .typescript }

        // 7. JavaScript density: function, const, =>
        let jsSignals = countOccurrences(of: ["function ", "const ", "=>"], in: sample)
        if jsSignals >= 2 { return .javascript }

        // 8. CSS: selector followed by { and ; inside
        if looksLikeCSS(sample) { return .css }

        return nil
    }

    private static func looksLikePython(_ lines: [String]) -> Bool {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isSuiteHeader = trimmed.hasPrefix("def ")
                || trimmed.hasPrefix("async def ")
                || trimmed.hasPrefix("class ")
            guard isSuiteHeader, trimmed.hasSuffix(":") else { continue }

            // A colon-terminated header means Python only when an indented
            // statement follows it (blank lines are allowed in between).
            for next in lines.dropFirst(index + 1) {
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { continue }
                if next.hasPrefix(" ") || next.hasPrefix("\t") { return true }
                break
            }
        }
        return false
    }

    private static func looksLikeTypeScript(_ sample: String, lines: [String]) -> Bool {
        let typeScriptMarkers = [
            "interface ", "enum ",
            ": string", ": number", ": boolean", ": void", ": any", ": unknown", ": never"
        ]
        if countOccurrences(of: typeScriptMarkers, in: sample) > 0 { return true }

        // `type Name = ...` is a TS alias; a bare `type ` mention (e.g. in a
        // comment) is not enough on its own.
        for line in lines.prefix(60) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if (trimmed.hasPrefix("type ") || trimmed.hasPrefix("export type "))
                && trimmed.contains("=") {
                return true
            }
        }
        return false
    }

    private static func countOccurrences(of patterns: [String], in text: String) -> Int {
        var count = 0
        for pattern in patterns {
            count += text.components(separatedBy: pattern).count - 1
        }
        return count
    }

    private static func looksLikeCSS(_ text: String) -> Bool {
        // Simple heuristic: has { and } and ; and at least one selector-like pattern
        guard text.contains("{"), text.contains("}"), text.contains(";") else { return false }
        // Look for a line that has a selector followed by {
        let lines = text.components(separatedBy: "\n")
        for line in lines.prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Selector patterns: .class {, #id {, tag {, *, @media
            if (trimmed.hasPrefix(".") || trimmed.hasPrefix("#") || trimmed.hasPrefix("@"))
                && trimmed.contains("{") {
                return true
            }
        }
        return false
    }
}
