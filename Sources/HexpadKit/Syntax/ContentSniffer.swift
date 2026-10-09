import Foundation

/// Sniffs file content to guess a language. Returns nil when unsure.
public enum ContentSniffer {
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

        // 5. Python density: def, import, from x import
        let pySignals = countOccurrences(of: ["def ", "import ", "from "], in: sample)
        if pySignals >= 2 { return .python }

        // 6. JavaScript density: function, const, =>
        let jsSignals = countOccurrences(of: ["function ", "const ", "=>"], in: sample)
        if jsSignals >= 2 { return .javascript }

        // 7. CSS: selector followed by { and ; inside
        if looksLikeCSS(sample) { return .css }

        return nil
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
