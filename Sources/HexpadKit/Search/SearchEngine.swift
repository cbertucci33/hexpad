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

    /// One-entry compiled-regex cache shared by every caller. In-editor find
    /// runs on the main thread, but Find in Files runs `searchInFiles` /
    /// `replaceInFiles` on a background queue, so the cache is guarded: a
    /// reader must never observe a new key paired with the previous pattern's
    /// compiled object.
    private struct RegexCacheKey: Hashable {
        let pattern: String
        let options: UInt
    }
    private static let cacheLock = NSLock()
    private static var cachedRegexKey: RegexCacheKey?
    private static var cachedRegex: NSRegularExpression?
    private static var regexCompileCount = 0

    /// Test hook: resets the one-entry cache and its compile counter.
    static func resetRegexCacheForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedRegexKey = nil
        cachedRegex = nil
        regexCompileCount = 0
    }

    /// Test hook: number of `NSRegularExpression` compilations since reset.
    static var regexCompileCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return regexCompileCount
    }

    /// Returns the cached regex for this effective pattern + options, compiling
    /// only on a miss. A pattern change evicts the previous entry naturally.
    private static func compiledRegex(pattern: String, options: SearchOptions) throws -> NSRegularExpression {
        let effectivePattern = regexPattern(for: pattern, options: options)
        let effectiveOptions = regexOptions(for: options)
        let key = RegexCacheKey(pattern: effectivePattern,
                                options: effectiveOptions.rawValue)
        cacheLock.lock()
        if cachedRegexKey == key, let cachedRegex {
            cacheLock.unlock()
            return cachedRegex
        }
        cacheLock.unlock()

        let regex = try NSRegularExpression(pattern: effectivePattern, options: effectiveOptions)

        cacheLock.lock()
        // Publish the value before the key (and under the lock) so a concurrent
        // reader can never pair this key with a different compiled pattern.
        cachedRegex = regex
        cachedRegexKey = key
        regexCompileCount += 1
        cacheLock.unlock()
        return regex
    }
    
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
    ///
    /// `limit` caps the number of matches collected and stops the scan once it
    /// is reached. A one-character query over a large buffer can match hundreds
    /// of thousands of times; callers that only paint or navigate a viewport
    /// pass a cap so the full range list and its per-match substrings are never
    /// built (mirroring how Find Characters in Range caps its carets).
    public static func search(_ text: String, pattern: String, options: SearchOptions,
                              range: NSRange? = nil, limit: Int? = nil) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        guard !pattern.isEmpty else { return matches }
        let maxMatches = limit.map { max(0, $0) } ?? Int.max
        guard maxMatches > 0 else { return matches }
        
        let nsText = text as NSString
        let searchRange = clampedRange(range, length: nsText.length)
        guard searchRange.length > 0 else { return matches }
        
        do {
            let regex = try compiledRegex(pattern: pattern, options: options)
            regex.enumerateMatches(in: text, options: [], range: searchRange) { result, _, stop in
                guard let result else { return }
                let matchedText = nsText.substring(with: result.range)
                matches.append(SearchMatch(range: result.range, text: matchedText))
                if matches.count >= maxMatches {
                    stop.pointee = true
                }
            }
        } catch {
            // Invalid regex pattern - treat as literal within the same range.
            let compareOptions: NSString.CompareOptions = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
            var loc = searchRange.location
            let end = searchRange.upperBound
            while loc < end, matches.count < maxMatches {
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
            let regex = try compiledRegex(pattern: pattern, options: options)
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
    ///
    /// `includeGlobs` / `excludeGlobs` are N++-style filters applied during file
    /// discovery (see ``findFiles(in:includeGlobs:excludeGlobs:maxBytes:skipsHiddenFiles:)``);
    /// empty filter lists keep the unfiltered behaviour.
    public static func searchInFiles(directory: URL, pattern: String, options: SearchOptions,
                                     maxBytes: Int = 4 * 1024 * 1024,
                                     includeGlobs: [String] = [],
                                     excludeGlobs: [String] = []) -> [(URL, [SearchMatch])] {
        var results: [(URL, [SearchMatch])] = []
        guard !pattern.isEmpty else { return results }

        for fileURL in findFiles(in: directory, includeGlobs: includeGlobs,
                                 excludeGlobs: excludeGlobs, maxBytes: maxBytes) {
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
    /// the search skips them. The discovery filters behave exactly as they do
    /// for ``searchInFiles``.
    public static func replaceInFiles(directory: URL, pattern: String, replacement: String,
                                      options: SearchOptions,
                                      maxBytes: Int = 4 * 1024 * 1024,
                                      includeGlobs: [String] = [],
                                      excludeGlobs: [String] = []) -> [(URL, Int)] {
        var results: [(URL, Int)] = []
        guard !pattern.isEmpty else { return results }

        for fileURL in findFiles(in: directory, includeGlobs: includeGlobs,
                                 excludeGlobs: excludeGlobs, maxBytes: maxBytes) {
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

    // MARK: - Find in Files discovery filters

    /// Parses an N++-style filter string into individual globs.
    ///
    /// N++ separates filters with semicolons (`*.cpp;*.h`); the box also accepts
    /// whitespace-separated globs (`*.swift *.md`) because that is how the
    /// filters are usually typed. Entries are trimmed and empty ones dropped, so
    /// both spellings produce the same two globs.
    public static func parseFilterGlobs(_ filter: String) -> [String] {
        filter
            .split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when `name` matches any glob in `patterns`.
    ///
    /// `*` matches any run of characters (including none), `?` matches exactly
    /// one, and every other character is literal. Matching is case-insensitive
    /// like N++'s filter box. An empty pattern list matches everything, which
    /// is the "no filters = all files" rule.
    public static func matchesGlob(_ name: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { globMatches($0, name: name) }
    }

    private static func globMatches(_ pattern: String, name: String) -> Bool {
        guard let regex = compileGlob(pattern) else { return false }
        let range = NSRange(location: 0, length: (name as NSString).length)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Compiles one glob to an anchored, case-insensitive regex. Returns nil
    /// only when the pattern cannot compile, which cannot happen for the
    /// escaped forms built here but keeps the matcher total.
    private static func compileGlob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex, options: [.caseInsensitive])
    }

    /// Discovers the regular files under `directory` that pass the include and
    /// exclude filters, in FileManager enumeration order.
    ///
    /// - includeGlobs: file-name globs (`*.swift;*.md`). Empty means every file.
    /// - excludeGlobs: globs matched against every path component below the
    ///   root (directory names and the file name). Exclusion wins: a file in an
    ///   excluded directory is dropped even when it matches an include glob.
    /// - maxBytes: files larger than this are skipped, matching the search and
    ///   replace ceilings.
    /// - skipsHiddenFiles: preserves the pre-existing Find in Files behaviour
    ///   (dotfiles are not walked). Pass false to search them; exclude globs
    ///   still apply either way.
    public static func findFiles(in directory: URL,
                                 includeGlobs: [String] = [],
                                 excludeGlobs: [String] = [],
                                 maxBytes: Int? = nil,
                                 skipsHiddenFiles: Bool = true) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if skipsHiddenFiles { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: options
        ) else { return [] }

        let rootComponents = directory.standardizedFileURL.pathComponents
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let maxBytes, let size = values?.fileSize, size > maxBytes { continue }

            let components = fileURL.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count else { continue }
            let relative = Array(components[rootComponents.count...])
            guard !relative.isEmpty else { continue }

            // Exclude wins: any path component (a directory name or the file
            // itself) matching an exclude glob drops the file.
            if excludeGlobs.contains(where: { glob in
                relative.contains { globMatches(glob, name: $0) }
            }) { continue }

            if !matchesGlob(relative.last ?? "", patterns: includeGlobs) { continue }
            files.append(fileURL)
        }
        return files
    }
}

// MARK: - Multi-select match iteration
//
// The Search > Multi-select commands repeatedly walk one collected match list:
// "next" picks the following unselected occurrence, "skip" excludes the one it
// just dropped. Keeping that pick in the Kit (rather than in a menu action)
// makes the no-wrap rule and the "skipped stays skipped" rule testable without
// a window, and gives every variant the same notion of "next".

public extension SearchEngine {

    /// Index of the first match whose location is at or after `location` and
    /// which is not in `excluded`.
    ///
    /// `matches` must be in ascending document order, which `search` always
    /// produces. Returning `nil` at the end is the deliberate no-wrap rule for
    /// the Multi-select commands: they never cycle back to the first match.
    static func nextMatchIndex(from location: Int,
                               in matches: [NSRange],
                               excluding excluded: [NSRange]) -> Int? {
        matches.firstIndex { range in
            range.location >= location && !excluded.contains(range)
        }
    }

    /// Whether `token` is one word token (alphanumerics plus `_`, matching the
    /// `\\b` boundaries Whole Word uses).
    ///
    /// The S18a token-style commands enforce whole-word matching for word
    /// tokens; the Select All / Skip multi-select commands follow the same
    /// precedent when they derive options from the find-bar query.
    static func isWordToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return wordRange(at: 0, in: token)?.length == (token as NSString).length
    }
}
