import Foundation

/// The user's collapsed fold ranges, stored independently of fold discovery.
///
/// Keeping this as its own value type is what lets re-tokenization rebuild a
/// ``FoldModel`` without losing fold state. Session persistence and the gutter
/// layer can hold a `FoldState` while the text and grammar change underneath.
///
/// Ranges in the set are not required to be currently foldable: a state can be
/// restored before the model is recomputed, and visibility clamps anything that
/// falls outside the document. ``FoldModel`` validates new operations against
/// its computed ranges.
public struct FoldState: Equatable, Codable {

    /// The collapsed ranges. A fold is identified by its span, so the kind is
    /// retained for presentation but does not affect set membership.
    public private(set) var collapsedRanges: Set<FoldRange>

    public init(collapsedRanges: Set<FoldRange> = []) {
        self.collapsedRanges = collapsedRanges
    }

    /// Whether no fold is collapsed.
    public var isEmpty: Bool { collapsedRanges.isEmpty }

    /// Number of collapsed ranges.
    public var count: Int { collapsedRanges.count }

    /// Whether `fold` is collapsed.
    public func isCollapsed(_ fold: FoldRange) -> Bool {
        collapsedRanges.contains(fold)
    }

    /// Whether the fold with `range` is collapsed.
    public func isCollapsed(_ range: NSRange) -> Bool {
        collapsedRanges.contains { $0.range == range }
    }

    /// Adds `fold` to the collapsed set.
    public mutating func insert(_ fold: FoldRange) {
        collapsedRanges.insert(fold)
    }

    /// Removes `fold` from the collapsed set.
    ///
    /// - Returns: `true` when the fold was collapsed.
    @discardableResult
    public mutating func remove(_ fold: FoldRange) -> Bool {
        collapsedRanges.remove(fold) != nil
    }

    /// Removes every collapsed range.
    public mutating func removeAll() {
        collapsedRanges.removeAll()
    }

    /// Adds `fold` when absent, or removes it when present.
    public mutating func toggle(_ fold: FoldRange) {
        if isCollapsed(fold) {
            collapsedRanges.remove(fold)
        } else {
            collapsedRanges.insert(fold)
        }
    }

    // MARK: - Edit remapping

    /// Remaps every collapsed range across an edit, returning a new state.
    ///
    /// This is a pure function: the receiver and its ranges are unchanged.
    ///
    /// - A fold entirely before the edit shifts by the edit's delta.
    /// - A fold entirely after the edit is unchanged.
    /// - An insertion at or before a fold's start shifts the fold; an insertion
    ///   strictly inside a fold expands it; an insertion at its end leaves it
    ///   alone.
    /// - A deletion or replacement strictly inside a fold shrinks or expands
    ///   it. An edit that touches either delimiter is treated as destroying the
    ///   construct, so the fold is dropped.
    public func remapped(for edit: FoldTextEdit) -> FoldState {
        var result = Set<FoldRange>()
        for fold in collapsedRanges {
            guard let range = FoldState.remappedRange(fold.range, for: edit) else { continue }
            result.insert(FoldRange(range: range, kind: fold.kind))
        }
        return FoldState(collapsedRanges: result)
    }

    /// Remaps a single UTF-16 range across an edit.
    ///
    /// - Returns: The new range, or `nil` when the edit destroyed the range.
    public static func remappedRange(_ range: NSRange, for edit: FoldTextEdit) -> NSRange? {
        let start = range.location
        let end = NSMaxRange(range)
        let editStart = edit.location
        let editEnd = editStart + edit.replacedLength

        // Pure insertion. Text inserted at the start is before the fold; text
        // inserted at the end is after it.
        if edit.replacedLength == 0 {
            if editStart <= start {
                return NSRange(location: start + edit.insertedLength, length: range.length)
            }
            if editStart < end {
                return NSRange(location: start, length: range.length + edit.insertedLength)
            }
            return range
        }

        // Edit is wholly before the fold.
        if editEnd <= start {
            return NSRange(location: start + edit.delta, length: range.length)
        }

        // Edit is wholly after the fold.
        if editStart >= end {
            return range
        }

        // The edit overlaps a boundary. Either delimiter may have been deleted,
        // so the construct no longer has a trustworthy span.
        let touchesStart = editStart <= start && editEnd > start
        let touchesEnd = editStart < end && editEnd >= end
        if touchesStart || touchesEnd {
            return nil
        }

        // The edit is strictly inside the fold; keep both delimiters and adjust
        // the interior length.
        let newLength = range.length + edit.delta
        guard newLength > 0 else { return nil }
        return NSRange(location: start, length: newLength)
    }
}
