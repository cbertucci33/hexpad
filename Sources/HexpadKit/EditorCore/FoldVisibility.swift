import Foundation

/// The visible portions of a document under a fold state.
///
/// Given a set of collapsed ranges, a visible range is the part of the document
/// the editor draws: everything outside the collapsed constructs. A collapsed
/// fold keeps its first line visible and hides from that line's terminator
/// through the end of the construct. A single-line fold (only produced when
/// `FoldConfiguration.foldsSingleLineRanges` is enabled) hides its entire span.
///
/// All positions and ranges are UTF-16 offsets. Positions inside a hidden range
/// map to the hidden range's visible start, which is where a caret placed at
/// the end of a collapsed opening line ends up.
public struct FoldVisibility: Equatable {

    /// Total UTF-16 length of the document.
    public let documentLength: Int

    /// Visible document ranges, sorted and non-overlapping.
    public let visibleRanges: [NSRange]

    /// Hidden document ranges, sorted, merged, and non-overlapping.
    public let hiddenRanges: [NSRange]

    public init(text: String, foldState: FoldState) {
        self.init(text: text, collapsedRanges: foldState.collapsedRanges)
    }

    public init(text: String, collapsedRanges: Set<FoldRange>) {
        let nsText = text as NSString
        let length = nsText.length
        self.documentLength = length
        let hidden = FoldVisibility.hiddenRanges(in: nsText, collapsedRanges: collapsedRanges)
        self.hiddenRanges = hidden
        self.visibleRanges = FoldVisibility.visibleRanges(in: nsText, hiddenRanges: hidden)
    }

    /// Total UTF-16 length of the visible text.
    public var visibleLength: Int {
        visibleRanges.reduce(0) { $0 + $1.length }
    }

    /// Whether `documentPosition` is drawn.
    public func isVisible(_ documentPosition: Int) -> Bool {
        let position = max(0, min(documentPosition, documentLength))
        return !hiddenRanges.contains { $0.location <= position && position < NSMaxRange($0) }
    }

    /// Maps a document UTF-16 position to its visible UTF-16 position.
    ///
    /// Positions inside a hidden range collapse onto the start of that hidden
    /// range. Positions outside the document are clamped.
    public func visiblePosition(ofDocumentPosition documentPosition: Int) -> Int {
        let position = max(0, min(documentPosition, documentLength))
        var hiddenBefore = 0
        for hidden in hiddenRanges {
            if position <= hidden.location { break }
            hiddenBefore += min(position, NSMaxRange(hidden)) - hidden.location
        }
        return position - hiddenBefore
    }

    /// Maps a visible UTF-16 position back to a document position.
    ///
    /// A visible position exactly at the start of a hidden gap maps to the
    /// hidden range's first document position. Visible positions outside the
    /// document are clamped.
    public func documentPosition(ofVisiblePosition visiblePosition: Int) -> Int {
        let position = max(0, min(visiblePosition, visibleLength))
        var hiddenBefore = 0
        for hidden in hiddenRanges {
            let visibleGapStart = hidden.location - hiddenBefore
            if position < visibleGapStart {
                return position + hiddenBefore
            }
            if position == visibleGapStart {
                return hidden.location
            }
            hiddenBefore += hidden.length
            let visibleGapEnd = NSMaxRange(hidden) - hiddenBefore
            if position < visibleGapEnd {
                return hidden.location
            }
        }
        return min(position + hiddenBefore, documentLength)
    }

    // MARK: - Computation

    private static func hiddenRanges(in text: NSString,
                                     collapsedRanges: Set<FoldRange>) -> [NSRange] {
        let length = text.length
        var spans: [NSRange] = []

        for fold in collapsedRanges {
            let start = max(0, min(fold.location, length))
            let end = max(start, min(fold.upperBound, length))
            guard end > start else { continue }

            let searchRange = NSRange(location: start, length: end - start)
            let newline = text.range(of: "\n", options: [], range: searchRange)
            let hiddenStart = newline.location == NSNotFound ? start : newline.location
            let hidden = NSRange(location: hiddenStart, length: end - hiddenStart)
            if hidden.length > 0 {
                spans.append(hidden)
            }
        }

        return merged(spans)
    }

    private static func visibleRanges(in text: NSString,
                                      hiddenRanges: [NSRange]) -> [NSRange] {
        let length = text.length
        var result: [NSRange] = []
        var cursor = 0

        for hidden in hiddenRanges {
            if hidden.location > cursor {
                result.append(NSRange(location: cursor, length: hidden.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(hidden))
        }
        if cursor < length {
            result.append(NSRange(location: cursor, length: length - cursor))
        }
        return result
    }

    private static func merged(_ spans: [NSRange]) -> [NSRange] {
        let sorted = spans.filter { $0.length > 0 }.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length > rhs.length
        }
        var result: [NSRange] = []
        for span in sorted {
            if let last = result.last, span.location <= NSMaxRange(last) {
                let start = min(last.location, span.location)
                let end = max(NSMaxRange(last), NSMaxRange(span))
                result[result.count - 1] = NSRange(location: start, length: end - start)
            } else {
                result.append(span)
            }
        }
        return result
    }
}
