import Foundation

/// Sparse, incrementally maintained token cache for one editor buffer.
///
/// The store never needs the whole document to be tokenized: callers ask for
/// the visible line band and the store fills in only the missing ranges. Edits
/// drop the cached tokens from the edited line onward and re-tokenize just that
/// line band, so typing cost scales with the viewport, not the document.
///
/// Above `largeFileThreshold` the store keeps only the current viewport in
/// memory; everything else intentionally falls back to plain text.
public final class TokenStore {

    /// Files larger than this are highlighted viewport-only.
    public static let largeFileThreshold = 1_000_000

    /// Lines of context tokenized above and below the requested range, so
    /// small scrolls do not immediately trigger another tokenization pass.
    public static let defaultViewportMargin = 40

    public private(set) var language: Language
    public private(set) var tokens: [Token] = []
    public private(set) var isLargeFile = false

    /// Length of the text the cached tokens currently describe.
    public private(set) var textLength = 0

    /// Character ranges (line-aligned) for which tokens have been generated.
    private var coveredRanges: [NSRange] = []
    private let viewportMargin: Int

    public init(language: Language = .plain, viewportMargin: Int = TokenStore.defaultViewportMargin) {
        self.language = language
        self.viewportMargin = max(0, viewportMargin)
    }

    // MARK: - Public API

    /// Clears the cache, optionally switching language.
    public func reset(language: Language? = nil) {
        if let language {
            self.language = language
        }
        tokens.removeAll(keepingCapacity: true)
        coveredRanges.removeAll(keepingCapacity: true)
        textLength = 0
        isLargeFile = false
    }

    /// Ensures tokens exist for `range` (expanded to whole lines plus the
    /// viewport margin) and returns that expanded line range.
    @discardableResult
    public func ensureTokens(for text: String, range: NSRange) -> NSRange {
        let nsText = text as NSString
        textLength = nsText.length
        isLargeFile = textLength > Self.largeFileThreshold

        let target = Self.lineRange(containing: range, in: nsText, margin: viewportMargin)
        guard language != .plain, target.length > 0 else {
            tokens.removeAll(keepingCapacity: true)
            coveredRanges.removeAll(keepingCapacity: true)
            return target
        }

        if isLargeFile {
            // Viewport-only cache: everything outside this range renders with
            // the theme's default foreground, never a stale highlight.
            tokens = SyntaxTokenizer.tokenize(text, language: language, in: target)
            coveredRanges = [target]
            return target
        }

        guard !Self.uncoveredRanges(in: target, covered: coveredRanges).isEmpty else {
            return target
        }

        // Tokenize the whole target rather than only the gaps: a token can span
        // a coverage boundary (multi-line string/comment), and the target is
        // viewport-sized by construction.
        let fresh = SyntaxTokenizer.tokenize(text, language: language, in: target)
        replaceTokens(in: target, with: fresh)
        addCovered(target)
        return target
    }

    /// Invalidates the line band touched by an edit, re-tokenizes only that
    /// band, and merges the result into the cache.
    ///
    /// Cached tokens before the edited line remain valid; everything from the
    /// edited line onward is dropped (its offsets shift with the edit) and the
    /// edited band is regenerated.
    @discardableResult
    public func update(text: String, language: Language, editedRange: NSRange?) -> NSRange {
        let nsText = text as NSString
        let newLength = nsText.length

        if self.language != language {
            reset(language: language)
        }
        // A programmatic edit with no range cannot be merged safely; rebuild
        // on the next viewport request instead.
        guard let editedRange, editedRange.location <= newLength else {
            reset(language: language)
            textLength = newLength
            isLargeFile = newLength > Self.largeFileThreshold
            return Self.lineRange(containing: editedRange ?? NSRange(location: 0, length: 0),
                                  in: nsText,
                                  margin: 0)
        }

        textLength = newLength
        isLargeFile = newLength > Self.largeFileThreshold
        let band = Self.lineRange(containing: editedRange, in: nsText, margin: 0)

        if isLargeFile {
            tokens.removeAll(keepingCapacity: true)
            coveredRanges.removeAll(keepingCapacity: true)
        } else {
            // Drop the edited line and everything after it; those offsets may
            // have moved by the edit delta. A covered range that crosses the
            // cut is not wholesale invalid, though: trim it at the cut so the
            // still-correct text before the edit stays covered and a later
            // viewport request does not re-tokenize it.
            let cut = band.location
            tokens.removeAll { NSMaxRange($0.range) > cut }
            coveredRanges = coveredRanges.compactMap { covered in
                let end = NSMaxRange(covered)
                guard end > cut else { return covered }
                let length = min(cut, end) - covered.location
                return length > 0 ? NSRange(location: covered.location, length: length) : nil
            }
        }

        let fresh = SyntaxTokenizer.tokenize(text, language: language, in: band)
        if isLargeFile {
            tokens = fresh
            coveredRanges = [band]
        } else {
            replaceTokens(in: band, with: fresh)
            addCovered(band)
        }
        return band
    }

    /// Cached tokens intersecting `range` (in document order).
    public func tokens(in range: NSRange) -> [Token] {
        guard !tokens.isEmpty, range.length > 0 else { return [] }

        // First token whose end is past the requested range's start.
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let limit = NSMaxRange(range)
        var result: [Token] = []
        var index = low
        while index < tokens.count, tokens[index].range.location < limit {
            result.append(tokens[index])
            index += 1
        }
        return result
    }

    // MARK: - Line geometry

    /// Expands `range` to whole logical lines plus `margin` lines on each side.
    public static func lineRange(containing range: NSRange, in text: NSString, margin: Int = 0) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let startLocation = min(max(0, range.location), length - 1)
        let endLocation = min(max(startLocation, NSMaxRange(range) - 1), length - 1)

        var start = lineStart(at: startLocation, in: text)
        var end = lineEnd(at: endLocation, in: text)

        var remaining = max(0, margin)
        while remaining > 0 && start > 0 {
            start = lineStart(at: start - 1, in: text)
            remaining -= 1
        }
        remaining = max(0, margin)
        while remaining > 0 && end < length {
            end = lineEnd(at: end, in: text)
            remaining -= 1
        }

        return NSRange(location: start, length: end - start)
    }

    private static func lineStart(at location: Int, in text: NSString) -> Int {
        var start = 0
        var end = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: location, length: 0))
        return start
    }

    private static func lineEnd(at location: Int, in text: NSString) -> Int {
        var start = 0
        var end = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: location, length: 0))
        return end
    }

    // MARK: - Range bookkeeping

    private static func uncoveredRanges(in target: NSRange, covered: [NSRange]) -> [NSRange] {
        var missing: [NSRange] = []
        var cursor = target.location
        let limit = NSMaxRange(target)

        for range in covered {
            let rangeEnd = NSMaxRange(range)
            if rangeEnd <= cursor { continue }
            if range.location >= limit { break }
            if range.location > cursor {
                missing.append(NSRange(location: cursor, length: min(range.location, limit) - cursor))
            }
            cursor = max(cursor, rangeEnd)
            if cursor >= limit { break }
        }
        if cursor < limit {
            missing.append(NSRange(location: cursor, length: limit - cursor))
        }
        return missing
    }

    private func addCovered(_ range: NSRange) {
        var merged: [NSRange] = []
        var pending = range
        var inserted = false

        for existing in coveredRanges {
            if NSMaxRange(existing) < pending.location {
                merged.append(existing)
            } else if existing.location > NSMaxRange(pending) {
                if !inserted {
                    merged.append(pending)
                    inserted = true
                }
                merged.append(existing)
            } else {
                let start = min(existing.location, pending.location)
                let end = max(NSMaxRange(existing), NSMaxRange(pending))
                pending = NSRange(location: start, length: end - start)
            }
        }
        if !inserted {
            merged.append(pending)
        }
        coveredRanges = merged
    }

    private func replaceTokens(in range: NSRange, with newTokens: [Token]) {
        var start = 0
        while start < tokens.count, NSMaxRange(tokens[start].range) <= range.location {
            start += 1
        }
        var end = start
        while end < tokens.count, tokens[end].range.location < NSMaxRange(range) {
            end += 1
        }
        tokens.replaceSubrange(start..<end, with: newTokens)
    }
}
