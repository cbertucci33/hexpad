import Foundation

/// Search options for find operations
public struct SearchOptions: OptionSet {
    public let rawValue: Int
    
    public static let caseSensitive = SearchOptions(rawValue: 1 << 0)
    public static let wholeWord = SearchOptions(rawValue: 1 << 1)
    public static let regex = SearchOptions(rawValue: 1 << 2)
    public static let wrapAround = SearchOptions(rawValue: 1 << 3)
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Result of a search operation
public struct SearchMatch {
    public let range: NSRange
    public let text: String
}

/// Search engine for document and file operations
public final class SearchEngine {
    
    /// Search text for matches
    public static func search(_ text: String, pattern: String, options: SearchOptions) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        guard !pattern.isEmpty else { return matches }
        
        do {
            let regexOptions: NSRegularExpression.Options = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
            let regexPattern: String
            
            if options.contains(.regex) {
                regexPattern = pattern
            } else {
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                if options.contains(.wholeWord) {
                    regexPattern = "\\b\(escaped)\\b"
                } else {
                    regexPattern = escaped
                }
            }
            
            let regex = try NSRegularExpression(pattern: regexPattern, options: regexOptions)
            let nsText = text as NSString
            let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            
            for result in results {
                let matchedText = nsText.substring(with: result.range)
                matches.append(SearchMatch(range: result.range, text: matchedText))
            }
        } catch {
            // Invalid regex pattern - treat as literal
            let nsText = text as NSString
            var loc = 0
            while loc < nsText.length {
                let range = nsText.range(of: pattern, options: options.contains(.caseSensitive) ? [] : [.caseInsensitive], range: NSRange(location: loc, length: nsText.length - loc))
                if range.location != NSNotFound {
                    matches.append(SearchMatch(range: range, text: nsText.substring(with: range)))
                    loc = range.upperBound
                } else {
                    break
                }
            }
        }
        
        return matches
    }
    
    /// Replace a single range (already computed by a prior search) with a replacement.
    /// Operates on NSString ranges so multi-byte/emoji code units stay length-safe.
    /// The range is clamped to the text bounds so a stale match can't crash the caller.
    public static func replaceRange(in text: String, replacement: String, range: NSRange) -> String {
        let nsText = text as NSString
        let maxLen = nsText.length
        guard range.location != NSNotFound, range.location < maxLen, range.length > 0 else { return text }
        let clampedLength = min(range.length, maxLen - range.location)
        return nsText.replacingCharacters(in: NSRange(location: range.location, length: clampedLength), with: replacement)
    }

    /// Replace all occurrences in text
    public static func replace(_ text: String, pattern: String, replacement: String, options: SearchOptions) -> String {
        guard !pattern.isEmpty else { return text }
        
        do {
            let regexOptions: NSRegularExpression.Options = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
            let regexPattern: String
            
            if options.contains(.regex) {
                regexPattern = pattern
            } else {
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                if options.contains(.wholeWord) {
                    regexPattern = "\\b\(escaped)\\b"
                } else {
                    regexPattern = escaped
                }
            }
            
            let regex = try NSRegularExpression(pattern: regexPattern, options: regexOptions)
            let nsText = text as NSString
            return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length), withTemplate: replacement)
        } catch {
            // Fallback to string replacement
            return text.replacingOccurrences(of: pattern, with: replacement, options: options.contains(.caseSensitive) ? [] : [.caseInsensitive])
        }
    }
    
    /// Search files in a directory recursively
    public static func searchInFiles(directory: URL, pattern: String, options: SearchOptions) -> [(URL, [SearchMatch])] {
        var results: [(URL, [SearchMatch])] = []
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return results
        }
        
        for case let fileURL as URL in enumerator {
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
            
            do {
                let data = try Data(contentsOf: fileURL)
                let text = String(data: data, encoding: .utf8) ?? ""
                let matches = search(text, pattern: pattern, options: options)
                if !matches.isEmpty {
                    results.append((fileURL, matches))
                }
            } catch {
                continue
            }
        }
        
        return results
    }
}
