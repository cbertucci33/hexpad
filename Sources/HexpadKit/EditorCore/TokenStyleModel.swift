import AppKit
import Foundation

/// The user's five token styles for one document.
///
/// Styles are range-oriented rather than line-oriented: each style is a list of
/// UTF-16 ranges that follow the text through edits. Notepad++ exposes five
/// named styles (1-5); this value keeps them keyed by that 1-based number and
/// preserves the invariant that one styled range belongs to exactly one style.
///
/// The state is independent of any document text. ``TokenStyleModel`` validates
/// it against the text it is built with, and the session projection stores only
/// offsets so a style can be restored before (or after) its text.
public struct TokenStyleState: Equatable {

    /// The styles Notepad++ exposes, 1-based.
    public static let styleNumbers = 1...5

    /// Number of usable styles.
    public static var styleCount: Int { styleNumbers.count }

    /// Ranges per style. Styles with no ranges are omitted.
    private var styles: [Int: [NSRange]]

    /// Creates a state, normalizing every style's ranges.
    ///
    /// Ranges are sorted, contiguous or overlapping ranges in the same style
    /// are merged, and empty/invalid entries are dropped. Overlaps *across*
    /// styles are left untouched here (decoded session data may contain them);
    /// ``add(_:style:)`` resolves them at edit time.
    public init(styles: [Int: [NSRange]] = [:]) {
        self.styles = TokenStyleState.normalized(styles)
    }

    /// Whether no range carries a style.
    public var isEmpty: Bool { styles.isEmpty }

    /// Total number of styled ranges across every style.
    public var styledRangeCount: Int {
        styles.values.reduce(0) { $0 + $1.count }
    }

    /// The ranges carrying `style`, in ascending order.
    public func ranges(for style: Int) -> [NSRange] {
        styles[style] ?? []
    }

    /// Whether `style` has at least one range.
    public func hasRanges(for style: Int) -> Bool {
        !(styles[style] ?? []).isEmpty
    }

    /// Every styled range, sorted by location. Ties prefer the lower style
    /// number so rendering and copying are deterministic.
    public var styledRanges: [(style: Int, range: NSRange)] {
        styles.flatMap { style, ranges in
            ranges.map { (style: style, range: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.style < rhs.style
        }
    }

    /// The union of every style's ranges, sorted and merged.
    ///
    /// Used by the "all styles" copy command: each stretch of text appears once
    /// even when two styles ever overlapped.
    public var allRanges: [NSRange] {
        TokenStyleState.merged(styles.values.flatMap { $0 })
    }

    /// Applies `style` to `range`.
    ///
    /// A range can carry only one style, so any overlap in another style is
    /// removed (whole ranges, not slices) before the new range is merged into
    /// its own style. This keeps the copy commands from duplicating text.
    ///
    /// - Returns: `true` when the state changed.
    @discardableResult
    public mutating func add(_ range: NSRange, style: Int) -> Bool {
        guard TokenStyleState.styleNumbers.contains(style),
              range.location != NSNotFound,
              range.location >= 0,
              range.length > 0 else { return false }

        var changed = false
        for other in TokenStyleState.styleNumbers where other != style {
            guard let existing = styles[other] else { continue }
            let filtered = existing.filter { !TokenStyleState.intersects($0, range) }
            guard filtered.count != existing.count else { continue }
            changed = true
            if filtered.isEmpty {
                styles.removeValue(forKey: other)
            } else {
                styles[other] = filtered
            }
        }

        let existing = styles[style] ?? []
        let merged = TokenStyleState.merged(existing + [range])
        if merged != existing {
            styles[style] = merged
            changed = true
        }
        return changed
    }

    /// Removes every range carrying `style`.
    ///
    /// - Returns: `true` when the style had any ranges.
    @discardableResult
    public mutating func removeAll(style: Int) -> Bool {
        styles.removeValue(forKey: style) != nil
    }

    /// Removes every styled range in every style.
    ///
    /// - Returns: `true` when anything was removed.
    @discardableResult
    public mutating func removeAll() -> Bool {
        guard !styles.isEmpty else { return false }
        styles.removeAll()
        return true
    }

    // MARK: - Validity

    /// Drops or clips ranges that fall outside `text`.
    public func revalidated(in text: String) -> TokenStyleState {
        let length = (text as NSString).length
        var clipped: [Int: [NSRange]] = [:]
        for (style, ranges) in styles {
            let valid = ranges.compactMap { TokenStyleState.clip($0, to: length) }
            if !valid.isEmpty {
                clipped[style] = valid
            }
        }
        return TokenStyleState(styles: clipped)
    }

    // MARK: - Edit remapping

    /// Remaps every styled range across an edit.
    ///
    /// This is a pure function mirroring ``BookmarkState/remapped(from:for:to:)``:
    /// the edit is expressed in pre-edit UTF-16 offsets and `newText` is the
    /// document after the edit.
    ///
    /// - A range entirely before the edit is unchanged.
    /// - A range entirely after the edit shifts by the edit's delta.
    /// - An insertion inside a range extends it; an insertion at its start
    ///   shifts it, so newly typed text is not retroactively styled.
    /// - A deletion or replacement that covers the whole range drops it;
    ///   partial overlaps shrink or grow the surviving portion.
    public func remapped(from oldText: String,
                         for edit: FoldTextEdit,
                         to newText: String) -> TokenStyleState {
        let newLength = (newText as NSString).length
        var mapped: [Int: [NSRange]] = [:]

        for (style, ranges) in styles {
            let result = ranges.compactMap { range -> NSRange? in
                TokenStyleState.map(range, through: edit, newLength: newLength)
            }
            if !result.isEmpty {
                mapped[style] = TokenStyleState.merged(result)
            }
        }
        return TokenStyleState(styles: mapped)
    }

    // MARK: - Helpers

    /// Maps one range through a single edit.
    static func map(_ range: NSRange,
                    through edit: FoldTextEdit,
                    newLength: Int) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let start = range.location
        let end = range.location + range.length
        let editStart = edit.location
        let editEnd = edit.location + edit.replacedLength
        let delta = edit.insertedLength - edit.replacedLength

        let mappedStart: Int
        let mappedEnd: Int

        if end <= editStart {
            // Entirely before the edit.
            mappedStart = start
            mappedEnd = end
        } else if start >= editEnd {
            // Entirely after the edit (including an insertion at the range
            // start, which shifts the range rather than absorbing the new text).
            mappedStart = start + delta
            mappedEnd = end + delta
        } else {
            // The edit overlaps the range.
            mappedStart = start < editStart ? start : editStart
            if end >= editEnd {
                mappedEnd = end + delta
            } else {
                mappedEnd = editStart + edit.insertedLength
            }
        }

        let clampedStart = min(max(0, mappedStart), newLength)
        let clampedEnd = min(max(clampedStart, mappedEnd), newLength)
        guard clampedEnd > clampedStart else { return nil }
        return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
    }

    /// Sorts ranges and merges overlapping or touching ones.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.location >= 0 && $0.length > 0 }
            .sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last,
               range.location <= last.location + last.length {
                let end = max(last.location + last.length, range.location + range.length)
                result[result.count - 1] = NSRange(location: last.location,
                                                   length: end - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Groups ranges by valid style and normalizes each style's list.
    static func normalized(_ styles: [Int: [NSRange]]) -> [Int: [NSRange]] {
        var result: [Int: [NSRange]] = [:]
        for (style, ranges) in styles where TokenStyleState.styleNumbers.contains(style) {
            let merged = TokenStyleState.merged(ranges)
            if !merged.isEmpty {
                result[style] = merged
            }
        }
        return result
    }

    static func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    static func clip(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0 else { return nil }
        let start = min(range.location, length)
        let end = min(range.location + range.length, length)
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Session persistence

extension TokenStyleState {

    /// JSON-ready projection nested under `editorState.tokenStyles`.
    ///
    /// The projection is offsets per style, not text, and styles are emitted in
    /// ascending order with each style's ranges sorted, so repeated saves are
    /// byte-identical. A state written before this slice has no key and restores
    /// empty.
    func toSessionData() -> [String: Any] {
        var styles: [String: [[Int]]] = [:]
        for style in TokenStyleState.styleNumbers.sorted() {
            let ranges = self.styles[style] ?? []
            guard !ranges.isEmpty else { continue }
            styles[String(style)] = ranges.map { [$0.location, $0.length] }
        }
        return ["styles": styles]
    }

    /// Restores a state written by ``toSessionData()``.
    ///
    /// Malformed styles and ranges are skipped individually. Out-of-bounds
    /// ranges are clipped when a ``TokenStyleModel`` is built over the live text,
    /// because session data deliberately does not carry the text.
    static func fromSessionData(_ data: [String: Any]?) -> TokenStyleState {
        guard let data,
              let rawStyles = data["styles"] as? [String: Any] else {
            return TokenStyleState()
        }

        var decoded: [Int: [NSRange]] = [:]
        for (key, value) in rawStyles {
            guard let style = Int(key),
                  TokenStyleState.styleNumbers.contains(style),
                  let entries = value as? [Any] else { continue }

            var ranges: [NSRange] = []
            for entry in entries {
                guard let pair = entry as? [Any],
                      pair.count == 2,
                      let location = intValue(pair[0]),
                      let length = intValue(pair[1]),
                      location >= 0,
                      length > 0 else { continue }
                ranges.append(NSRange(location: location, length: length))
            }
            if !ranges.isEmpty {
                decoded[style] = ranges
            }
        }
        return TokenStyleState(styles: decoded)
    }

    // JSONSerialization hands numbers back as NSNumber; callers may also supply
    // native Swift numbers. Accept both.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}

/// The five token styles of one document, kept in step with its current text.
///
/// Like ``BookmarkModel`` this model is pure and Kit-side: it owns the text only
/// to answer range questions and to run occurrence searches. The app layer
/// renders ``tokenStyleState`` and routes edits through ``remap(for:in:)``.
public struct TokenStyleModel {

    /// The document text the ranges are valid against.
    public private(set) var text: String

    /// The styled ranges, persisted independently of the text.
    public private(set) var tokenStyleState: TokenStyleState

    /// Creates a model, dropping or clipping ranges the text cannot hold.
    public init(text: String, tokenStyleState: TokenStyleState = TokenStyleState()) {
        self.text = text
        self.tokenStyleState = tokenStyleState.revalidated(in: text)
    }

    /// Whether no range is styled.
    public var isEmpty: Bool { tokenStyleState.isEmpty }

    /// The ranges carrying `style`.
    public func ranges(for style: Int) -> [NSRange] {
        tokenStyleState.ranges(for: style)
    }

    /// Whether `style` has at least one range.
    public func hasRanges(for style: Int) -> Bool {
        tokenStyleState.hasRanges(for: style)
    }

    /// Every styled range across every style, sorted and merged.
    public var allRanges: [NSRange] { tokenStyleState.allRanges }

    // MARK: - Mutations

    /// Styles `range`, clipping it to the document.
    ///
    /// - Returns: `true` when the state changed.
    @discardableResult
    public mutating func style(_ range: NSRange, as style: Int) -> Bool {
        guard let clipped = TokenStyleState.clip(range, to: (text as NSString).length) else {
            return false
        }
        return tokenStyleState.add(clipped, style: style)
    }

    /// Styles every occurrence of `token`, matching Notepad++'s
    /// "Style All Occurrences of Token".
    ///
    /// Word-like tokens match whole words only (`foo` does not match inside
    /// `foobar`). Selections containing punctuation or whitespace are matched
    /// literally, so styling `a + b` styles exactly that text.
    ///
    /// - Returns: `true` when the state changed.
    @discardableResult
    public mutating func styleAllOccurrences(of token: String, as style: Int) -> Bool {
        let ranges = TokenStyleModel.occurrenceRanges(of: token, in: text)
        guard !ranges.isEmpty else { return false }
        var changed = false
        for range in ranges {
            if tokenStyleState.add(range, style: style) {
                changed = true
            }
        }
        return changed
    }

    /// Removes every range carrying `style`.
    @discardableResult
    public mutating func removeAll(style: Int) -> Bool {
        tokenStyleState.removeAll(style: style)
    }

    /// Removes every styled range.
    @discardableResult
    public mutating func removeAll() -> Bool {
        tokenStyleState.removeAll()
    }

    // MARK: - Navigation

    /// The next styled range of `style` strictly after `location`, wrapping.
    ///
    /// A caret inside a styled range therefore advances to the following
    /// range; with a single range the same range's start is returned.
    public func nextRange(for style: Int, after location: Int) -> NSRange? {
        let ranges = tokenStyleState.ranges(for: style)
        return ranges.first { $0.location > location } ?? ranges.first
    }

    /// The previous styled range of `style` wholly before `location`, wrapping.
    ///
    /// Using the range's end rather than its start means a caret in the middle
    /// of a range jumps to the previous range, not back to the one it is in.
    public func previousRange(for style: Int, before location: Int) -> NSRange? {
        let ranges = tokenStyleState.ranges(for: style)
        return ranges.last { $0.location + $0.length <= location } ?? ranges.last
    }

    // MARK: - Copying

    /// The text of every range carrying `style`, in document order, separated
    /// by newlines. `nil` when the style is empty.
    public func styledText(for style: Int) -> String? {
        let ranges = tokenStyleState.ranges(for: style)
        guard !ranges.isEmpty else { return nil }
        let ns = text as NSString
        return ranges
            .filter { $0.location + $0.length <= ns.length }
            .map { ns.substring(with: $0) }
            .joined(separator: "\n")
    }

    /// The text of every styled range across all styles, each stretch once.
    public func allStyledText() -> String? {
        let ranges = tokenStyleState.allRanges
        guard !ranges.isEmpty else { return nil }
        let ns = text as NSString
        return ranges
            .filter { $0.location + $0.length <= ns.length }
            .map { ns.substring(with: $0) }
            .joined(separator: "\n")
    }

    // MARK: - Remapping

    /// The state remapped across `edit`, without adopting the new text.
    public func remappedState(for edit: FoldTextEdit, in newText: String) -> TokenStyleState {
        tokenStyleState.remapped(from: text, for: edit, to: newText)
    }

    /// A new model over `newText` with the ranges remapped across `edit`.
    public func remapped(for edit: FoldTextEdit, in newText: String) -> TokenStyleModel {
        TokenStyleModel(text: newText,
                        tokenStyleState: remappedState(for: edit, in: newText))
    }

    /// Applies an edit: remaps the ranges and adopts `newText`.
    public mutating func remap(for edit: FoldTextEdit, in newText: String) {
        tokenStyleState = remappedState(for: edit, in: newText)
        text = newText
    }

    /// Adopts `newText` without an edit, clipping ranges that still fit.
    public mutating func updateText(_ newText: String) {
        text = newText
        tokenStyleState = tokenStyleState.revalidated(in: newText)
    }

    /// The state revalidated against `newText`.
    public func revalidatedState(in newText: String) -> TokenStyleState {
        tokenStyleState.revalidated(in: newText)
    }

    // MARK: - Occurrence search

    /// All non-overlapping occurrences of `token` in `text`.
    ///
    /// Word-like tokens (alphanumerics plus `_`) require word boundaries;
    /// anything else is matched as literal text.
    public static func occurrenceRanges(of token: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        let tokenLength = (token as NSString).length
        guard tokenLength > 0, ns.length >= tokenLength else { return [] }

        let wholeWord = isWordToken(token)
        var result: [NSRange] = []
        var searchLocation = 0

        while searchLocation <= ns.length - tokenLength {
            let searchRange = NSRange(location: searchLocation,
                                      length: ns.length - searchLocation)
            let found = ns.range(of: token, options: [], range: searchRange)
            guard found.location != NSNotFound else { break }
            if !wholeWord || isWholeWord(found, in: ns) {
                result.append(found)
            }
            searchLocation = found.location + max(1, found.length)
        }
        return result
    }

    private static func isWordToken(_ token: String) -> Bool {
        let ns = token as NSString
        guard ns.length > 0 else { return false }
        for index in 0..<ns.length where !isWordCharacter(ns.character(at: index)) {
            return false
        }
        return true
    }

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        if range.location > 0, isWordCharacter(text.character(at: range.location - 1)) {
            return false
        }
        let end = range.location + range.length
        if end < text.length, isWordCharacter(text.character(at: end)) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return wordCharacters.contains(scalar)
    }

    private static let wordCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_"))
}

/// Theme-aware background colours for the five token styles.
///
/// The palette derives every colour from the system accent hue so the editor's
/// built-in themes stay coherent: the five styles rotate that hue by
/// `0 / 0.28 / 0.50 / 0.68 / 0.85`, with a lower brightness on light themes and
/// a higher one on dark themes. Alpha stays low (0.22 light, 0.30 dark) so the
/// text underneath remains readable.
public enum TokenStylePalette {

    /// The five background colours in style order.
    public static func colors(for theme: Theme) -> [NSColor] {
        let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)
            ?? NSColor.systemBlue.usingColorSpace(.deviceRGB)
            ?? NSColor.blue
        let baseHue = accent.hueComponent
        let dark = luminance(theme.background) < 0.5
        let saturation: CGFloat = dark ? 0.70 : 0.65
        let brightness: CGFloat = dark ? 0.95 : 0.75
        let alpha: CGFloat = dark ? 0.30 : 0.22
        let offsets: [CGFloat] = [0, 0.28, 0.50, 0.68, 0.85]

        return offsets.map { offset in
            var hue = (baseHue + offset).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            return NSColor(hue: hue,
                           saturation: saturation,
                           brightness: brightness,
                           alpha: alpha)
        }
    }

    /// The background colour for `style`, or `nil` outside 1...5.
    public static func color(for style: Int, theme: Theme) -> NSColor? {
        let colors = colors(for: theme)
        guard style >= 1, style <= colors.count else { return nil }
        return colors[style - 1]
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? NSColor.white
        return 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
    }
}
