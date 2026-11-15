import Foundation

/// Search options for find operations
public struct SearchOptions: OptionSet {
    public let rawValue: Int
    
    public static let caseSensitive = SearchOptions(rawValue: 1 << 0)
    public static let wholeWord = SearchOptions(rawValue: 1 << 1)
    public static let regex = SearchOptions(rawValue: 1 << 2)
    public static let wrapAround = SearchOptions(rawValue: 1 << 3)
    /// Restrict the operation to the caller-supplied range (the editor's
    /// selection). The range itself is passed to `search`/`replace`; this flag
    /// is what the UI keeps in its option set.
    public static let inSelection = SearchOptions(rawValue: 1 << 4)
    
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
    
    /// True when `pattern` compiles as a regex. SearchEngine falls back to a
    /// literal pass on failure, so callers need this to tell the user.
    public static func isValidRegex(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Search text for matches.
    ///
    /// `range` limits the search to a substring (the editor's selection) while
    /// returned match ranges stay absolute offsets into `text`. Passing nil
    /// searches the whole buffer.
    public static func search(_ text: String, pattern: String, options: SearchOptions,
                              range: NSRange? = nil) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        guard !pattern.isEmpty else { return matches }
        
        let nsText = text as NSString
        let searchRange = clampedRange(range, length: nsText.length)
        guard searchRange.length > 0 else { return matches }
        
        do {
            let regex = try NSRegularExpression(pattern: regexPattern(for: pattern, options: options),
                                                options: regexOptions(for: options))
            let results = regex.matches(in: text, options: [], range: searchRange)
            
            for result in results {
                let matchedText = nsText.substring(with: result.range)
                matches.append(SearchMatch(range: result.range, text: matchedText))
            }
        } catch {
            // Invalid regex pattern - treat as literal within the same range.
            let compareOptions: NSString.CompareOptions = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
            var loc = searchRange.location
            let end = searchRange.upperBound
            while loc < end {
                let remaining = NSRange(location: loc, length: end - loc)
                let found = nsText.range(of: pattern, options: compareOptions, range: remaining)
                guard found.location != NSNotFound else { break }
                if !options.contains(.wholeWord) || isWholeWord(found, in: nsText) {
                    matches.append(SearchMatch(range: found, text: nsText.substring(with: found)))
                }
                loc = found.location + max(found.length, 1)
            }
        }
        
        return matches
    }
    
    /// Options shared by search and replace. `.anchorsMatchLines` gives ^ and $
    /// Notepad++ semantics: they match at every line boundary, not only at the
    /// start/end of the whole buffer.
    private static func regexOptions(for options: SearchOptions) -> NSRegularExpression.Options {
        var regexOptions: NSRegularExpression.Options = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
        regexOptions.insert(.anchorsMatchLines)
        return regexOptions
    }
    
    /// Builds the effective regex. Literal searches are escaped first; whole
    /// word wraps either mode so `foo` does not match inside `foobar`.
    private static func regexPattern(for pattern: String, options: SearchOptions) -> String {
        let base = options.contains(.regex) ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        guard options.contains(.wholeWord) else { return base }
        return "\\b(?:\(base))\\b"
    }
    
    /// Clamps a caller-provided range to the buffer, treating a missing or
    /// invalid range as "the whole text".
    private static func clampedRange(_ range: NSRange?, length: Int) -> NSRange {
        guard let range, range.location != NSNotFound, range.location >= 0 else {
            return NSRange(location: 0, length: length)
        }
        let location = min(range.location, length)
        let clampedLength = max(0, min(range.length, length - location))
        return NSRange(location: location, length: clampedLength)
    }
    
    /// Used only by the literal fallback for an invalid regex; `\b` handles the
    /// normal whole-word path, but the fallback never reaches that code.
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if range.location > 0,
           let scalar = UnicodeScalar(text.character(at: range.location - 1)),
           wordCharacters.contains(scalar) {
            return false
        }
        let after = range.location + range.length
        if after < text.length,
           let scalar = UnicodeScalar(text.character(at: after)),
           wordCharacters.contains(scalar) {
            return false
        }
        return true
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

    /// Replace all occurrences in text. When `range` is supplied only matches
    /// inside that range are replaced; the rest of the text is preserved.
    public static func replace(_ text: String, pattern: String, replacement: String,
                               options: SearchOptions, range: NSRange? = nil) -> String {
        guard !pattern.isEmpty else { return text }
        
        let nsText = text as NSString
        let searchRange = clampedRange(range, length: nsText.length)
        guard searchRange.length > 0 else { return text }
        
        do {
            let regex = try NSRegularExpression(pattern: regexPattern(for: pattern, options: options),
                                                options: regexOptions(for: options))
            // Literal mode must treat the replacement as literal text too;
            // otherwise $1 and backslashes get template-mangled.
            let template = options.contains(.regex) ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
            return regex.stringByReplacingMatches(in: text, options: [], range: searchRange, withTemplate: template)
        } catch {
            // Invalid regex: replace literal text inside the requested range.
            // Whole-word mode stays meaningful even on this fallback path.
            if options.contains(.wholeWord) {
                let literalPattern = "\\b\(NSRegularExpression.escapedPattern(for: pattern))\\b"
                if let fallback = try? NSRegularExpression(pattern: literalPattern, options: regexOptions(for: options)) {
                    return fallback.stringByReplacingMatches(
                        in: text, options: [], range: searchRange,
                        withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
                }
            }
            let before = nsText.substring(to: searchRange.location)
            let slice = nsText.substring(with: searchRange)
            let after = nsText.substring(from: searchRange.upperBound)
            let compareOptions: NSString.CompareOptions = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
            return before + slice.replacingOccurrences(of: pattern, with: replacement, options: compareOptions) + after
        }
    }
    
    /// Search files in a directory recursively.
    /// Files over `maxBytes` are skipped and non-UTF-8 files are decoded via a
    /// lossy fallback, so a stray binary or a 200MB log cannot stall or crash
    /// the whole search.
    public static func searchInFiles(directory: URL, pattern: String, options: SearchOptions,
                                     maxBytes: Int = 4 * 1024 * 1024) -> [(URL, [SearchMatch])] {
        var results: [(URL, [SearchMatch])] = []
        guard !pattern.isEmpty else { return results }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return results
        }
        
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > maxBytes { continue }
            
            do {
                let data = try Data(contentsOf: fileURL)
                var text = String(data: data, encoding: .utf8)
                if text == nil {
                    // Lossy decode keeps Latin-1-ish sources searchable.
                    text = String(decoding: data, as: UTF8.self)
                }
                guard let body = text else { continue }
                let matches = search(body, pattern: pattern, options: options)
                if !matches.isEmpty {
                    results.append((fileURL, matches))
                }
            } catch {
                continue
            }
        }
        
        return results
    }
    
    /// Replace all matches in every searchable file under `directory` and
    /// report how many replacements each touched file received.
    ///
    /// Only UTF-8 files are rewritten: `searchInFiles` can lossily decode other
    /// encodings for reading, but writing that decoded text back would corrupt
    /// the original bytes. Files over `maxBytes` are skipped for the same reason
    /// the search skips them.
    public static func replaceInFiles(directory: URL, pattern: String, replacement: String,
                                      options: SearchOptions,
                                      maxBytes: Int = 4 * 1024 * 1024) -> [(URL, Int)] {
        var results: [(URL, Int)] = []
        guard !pattern.isEmpty else { return results }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return results
        }
        
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > maxBytes { continue }
            
            do {
                let data = try Data(contentsOf: fileURL)
                guard let body = String(data: data, encoding: .utf8) else { continue }
                let matches = search(body, pattern: pattern, options: options)
                guard !matches.isEmpty else { continue }
                
                let newText = replace(body, pattern: pattern, replacement: replacement, options: options)
                guard newText != body else { continue }
                
                try newText.write(to: fileURL, atomically: true, encoding: .utf8)
                results.append((fileURL, matches.count))
            } catch {
                continue
            }
        }
        
        return results
    }
}
