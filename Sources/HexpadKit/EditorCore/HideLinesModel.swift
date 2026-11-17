import Foundation

/// The lines a document hides without deleting them.
///
/// Hiding is independent of folding: a fold is a construct discovered from the
/// grammar, while a hidden range is whatever whole lines the user selected and
/// asked to hide. The text stays in the buffer, so search, line operations,
/// saving and undo all keep seeing the full document. Only presentation (layout
/// and the gutter) treats these lines as absent.
///
/// Line numbers are 1-based and inclusive, matching the gutter and
/// ``GutterGeometry``. Ranges are normalized and merged on insert, so two
/// adjacent hides become one range (the margin shows one symbol per range and a
/// click unhides the whole contiguous block).
public struct HideLinesState: Equatable {

    /// Hidden line ranges, sorted, non-overlapping and non-adjacent.
    public private(set) var lineRanges: [ClosedRange<Int>]

    public init(lineRanges: [ClosedRange<Int>] = []) {
        self.lineRanges = HideLinesState.normalized(lineRanges)
    }

    public var isEmpty: Bool { lineRanges.isEmpty }

    /// Whether the 1-based `line` is hidden.
    public func isHidden(line: Int) -> Bool {
        lineRanges.contains { $0.contains(line) }
    }

    /// Hides `range`, merging it with any touching range.
    ///
    /// - Returns: `true` when the state changed.
    @discardableResult
    public mutating func hide(_ range: ClosedRange<Int>) -> Bool {
        let lower = max(1, range.lowerBound)
        guard range.upperBound >= lower else { return false }
        let before = lineRanges
        lineRanges = HideLinesState.normalized(lineRanges + [lower...range.upperBound])
        return lineRanges != before
    }

    /// Unhides every range that intersects `range`.
    ///
    /// The requested range does not have to match a stored range exactly: a
    /// marker click and a selection that crosses a hidden block both resolve to
    /// the stored ranges they touch, and each is removed whole.
    ///
    /// - Returns: `true` when the state changed.
    @discardableResult
    public mutating func unhide(_ range: ClosedRange<Int>) -> Bool {
        let before = lineRanges
        lineRanges.removeAll { $0.overlaps(range) }
        return lineRanges != before
    }

    /// Unhides every hidden range.
    ///
    /// - Returns: The number of ranges removed.
    @discardableResult
    public mutating func unhideAll() -> Int {
        let removed = lineRanges.count
        lineRanges.removeAll()
        return removed
    }

    // MARK: - Renumbering

    /// The gutter number shown for `line`, or `nil` when the line is hidden.
    ///
    /// Visible lines are renumbered consecutively, so the row after a hidden
    /// block does not skip numbers. Display numbering deliberately differs from
    /// the 1-based document line that bookmarks, folds and the status bar use.
    public func displayNumber(forLine line: Int, lineCount: Int) -> Int? {
        guard line >= 1, line <= lineCount, !isHidden(line: line) else { return nil }
        return line - hiddenLineCount(before: line)
    }

    /// Number of hidden lines strictly before `line`.
    public func hiddenLineCount(before line: Int) -> Int {
        lineRanges.reduce(0) { total, range in
            let upper = min(line - 1, range.upperBound)
            guard upper >= range.lowerBound else { return total }
            return total + (upper - range.lowerBound + 1)
        }
    }

    /// Number of hidden lines in a document with `lineCount` lines. Ranges
    /// restored from an older session are clipped to the live text.
    public func hiddenLineCount(lineCount: Int) -> Int {
        guard lineCount > 0 else { return 0 }
        return lineRanges.reduce(0) { total, range in
            let lower = max(1, range.lowerBound)
            let upper = min(lineCount, range.upperBound)
            guard upper >= lower else { return total }
            return total + (upper - lower + 1)
        }
    }

    /// Number of gutter rows a document with `lineCount` lines still shows.
    public func visibleLineCount(lineCount: Int) -> Int {
        max(0, lineCount - hiddenLineCount(lineCount: lineCount))
    }

    /// The logical line whose margin carries `range`'s unhide marker.
    ///
    /// A hidden row has no layout, so the marker cannot live on its own first
    /// line. It is drawn on the last visible line above the range; a range that
    /// starts at line 1 is marked on the first visible line below. `nil` means
    /// every line is hidden, so there is no row to click.
    public func anchorLine(for range: ClosedRange<Int>, lineCount: Int) -> Int? {
        guard lineCount > 0 else { return nil }
        let lower = max(1, range.lowerBound)
        let upper = min(lineCount, range.upperBound)
        guard lower <= upper else { return nil }

        let above = lower - 1
        if above >= 1, !isHidden(line: above) { return above }

        var below = upper + 1
        while below <= lineCount {
            if !isHidden(line: below) { return below }
            below += 1
        }
        return nil
    }

    private static func normalized(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        let sorted = ranges
            .map { max(1, $0.lowerBound)...max(max(1, $0.lowerBound), $0.upperBound) }
            .sorted { $0.lowerBound < $1.lowerBound }

        var result: [ClosedRange<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Maps hidden lines onto UTF-16 spans for layout.
///
/// The editor's glyph hider consumes character ranges; the state itself is
/// line-based so it survives edits elsewhere in the document without remapping
/// offsets. A hidden range includes its trailing newline, which is what makes
/// the next visible line move up into the hidden row's place.
public enum HideLinesVisibility {

    /// UTF-16 spans hidden by `state`, in document order.
    public static func characterRanges(for state: HideLinesState, in text: String) -> [NSRange] {
        let index = LineIndex(text)
        return state.lineRanges.compactMap { characterRange(for: $0, in: index) }
    }

    /// UTF-16 span of one hidden line range (including its final newline).
    ///
    /// Returns `nil` when the range no longer names a line in the live text,
    /// which is how a stale session range becomes a no-op instead of hiding an
    /// arbitrary offset.
    public static func characterRange(for range: ClosedRange<Int>,
                                      in index: LineIndex) -> NSRange? {
        let lineCount = index.count
        let first = max(1, range.lowerBound)
        let last = min(lineCount, range.upperBound)
        guard first <= last else { return nil }

        let start = index.firstCharIndex(of: first)
        let end = last < lineCount ? index.firstCharIndex(of: last + 1) : index.textLength
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Session persistence

extension HideLinesState {

    /// JSON-ready projection, nested under `editorState.hiddenRanges`.
    ///
    /// Stores 1-based line numbers rather than text or offsets: the hidden
    /// lines are a property of the document's line structure, and a restored
    /// session re-resolves them against whatever text is live.
    public func toSessionData() -> [String: Any] {
        [
            "ranges": lineRanges.map {
                ["start": $0.lowerBound, "end": $0.upperBound]
            }
        ]
    }

    /// Restores a state written by ``toSessionData()``.
    ///
    /// Sessions written before hidden lines existed have no key and restore as
    /// an empty state. Malformed entries are skipped individually.
    public static func fromSessionData(_ data: [String: Any]?) -> HideLinesState {
        guard let data,
              let entries = data["ranges"] as? [[String: Any]] else {
            return HideLinesState()
        }

        var state = HideLinesState()
        for entry in entries {
            guard let start = intValue(entry["start"]), start >= 1,
                  let end = intValue(entry["end"]), end >= start else {
                continue
            }
            state.hide(start...end)
        }
        return state
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}
