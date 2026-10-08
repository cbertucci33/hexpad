import Foundation

/// Operations on line-oriented text
public struct LineOps {
    
    /// Sort lines alphabetically (ascending)
    public static func sortAscending(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: "\n")
    }
    
    /// Sort lines alphabetically (descending)
    public static func sortDescending(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.sorted { $0.lowercased() > $1.lowercased() }.joined(separator: "\n")
    }
    
    /// Remove duplicate lines (keeping first occurrence)
    public static func removeDuplicates(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            if !seen.contains(line) {
                seen.insert(line)
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }
    
    /// Remove blank lines
    public static func removeBlankLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
    
    /// Join all lines into a single line
    public static func joinLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.joined(separator: " ")
    }
    
    /// Split lines by a delimiter
    public static func splitLines(_ text: String, delimiter: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.replacingOccurrences(of: delimiter, with: "\n") }.joined(separator: "\n")
    }
    
    /// Reverse the order of lines
    public static func reverseLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.reversed().joined(separator: "\n")
    }
    
    /// Trim leading whitespace from all lines
    public static func trimLeading(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
    
    /// Trim trailing whitespace from all lines
    public static func trimTrailing(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
    
    /// Trim whitespace from both sides of all lines
    public static func trimAll(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
    
    /// Indent selected lines
    public static func indent(_ text: String, by amount: Int) -> String {
        let prefix = String(repeating: " ", count: amount)
        let lines = text.components(separatedBy: "\n")
        return lines.map { prefix + $0 }.joined(separator: "\n")
    }
    
    /// Dedent selected lines
    public static func dedent(_ text: String, by amount: Int) -> String {
        let prefix = String(repeating: " ", count: amount)
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.hasPrefix(prefix) ? String($0.dropFirst(amount)) : $0 }.joined(separator: "\n")
    }
}
