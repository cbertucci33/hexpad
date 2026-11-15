import Foundation

/// An ordered collection of independent text carets for multi-caret editing.
///
/// Each caret is a UTF-16 `NSRange` in the document: a zero-length range is a
/// plain insertion point, while a non-zero range represents a selection. The
/// list is always kept in ascending document order (by location) and
/// normalized so that no two carets overlap.
///
/// The model is deliberately pure and Kit-side: it has no knowledge of
/// `NSTextView`, notifications, or the app target. Applying a transform is
/// handled by ``MultiCaretApplier``.
public struct MultiCaretState: Equatable {

    /// Carets in ascending document order. The first caret is the primary.
    public private(set) var carets: [NSRange]

    /// Creates a state from an arbitrary list of carets.
    ///
    /// The input is normalized: invalid ranges are dropped, the list is sorted
    /// into document order, and overlapping ranges are merged into their
    /// outermost bounding range. Identical insertion points collapse to one.
    public init(carets: [NSRange] = []) {
        self.carets = MultiCaretState.normalized(carets)
    }

    /// Creates a state containing a single caret.
    public init(caret: NSRange) {
        self.init(carets: [caret])
    }

    /// Creates a state containing a single zero-length caret at `location`.
    public init(caretAt location: Int) {
        self.init(caret: NSRange(location: location, length: 0))
    }

    /// Whether there are no carets.
    public var isEmpty: Bool { carets.isEmpty }

    /// Number of carets after normalization.
    public var count: Int { carets.count }

    /// The primary caret: the first caret in document order, if any.
    public var primaryCaret: NSRange? { carets.first }

    /// Whether every caret is a zero-length insertion point.
    public var isInsertionOnly: Bool { carets.allSatisfy { $0.length == 0 } }

    /// The smallest range that contains every caret, or `nil` when empty.
    public var mergedBoundingRange: NSRange? {
        guard let first = carets.first else { return nil }
        let end = carets.reduce(first.upperBound) { max($0, $1.upperBound) }
        return NSRange(location: first.location, length: end - first.location)
    }

    /// Whether the stored carets are already sorted and non-overlapping.
    ///
    /// States created through this type are always valid; this is useful for
    /// asserting invariants in tests and at API boundaries.
    public var isValid: Bool {
        carets == MultiCaretState.normalized(carets)
    }

    // MARK: - Mutation helpers

    /// Adds a caret, merging it with any caret it overlaps.
    public mutating func addCaret(_ caret: NSRange) {
        carets = MultiCaretState.normalized(carets + [caret])
    }

    /// Adds a zero-length caret at `location`, merging duplicates.
    public mutating func addCaret(at location: Int) {
        addCaret(NSRange(location: location, length: 0))
    }

    /// Removes the caret at `location`, if one exists.
    ///
    /// - Returns: `true` when a caret was removed.
    @discardableResult
    public mutating func removeCaret(at location: Int) -> Bool {
        guard let index = carets.firstIndex(where: { $0.location == location }) else {
            return false
        }
        carets.remove(at: index)
        return true
    }

    /// Removes every caret equal to `caret`.
    ///
    /// - Returns: `true` when at least one caret was removed.
    @discardableResult
    public mutating func removeCaret(_ caret: NSRange) -> Bool {
        let previousCount = carets.count
        carets.removeAll { $0 == caret }
        return carets.count != previousCount
    }

    /// Adds `caret` when absent, or removes it when already present.
    public mutating func toggleCaret(_ caret: NSRange) {
        if carets.contains(caret) {
            removeCaret(caret)
        } else {
            addCaret(caret)
        }
    }

    /// Toggles a zero-length caret at `location`.
    public mutating func toggleCaret(at location: Int) {
        if carets.contains(where: { $0.location == location }) {
            removeCaret(at: location)
        } else {
            addCaret(at: location)
        }
    }

    /// Collapses the state to its primary (first) caret, in place.
    public mutating func collapseToPrimary() {
        if let primary = carets.first {
            carets = [primary]
        }
    }

    /// Returns a state containing only the primary caret.
    public func collapsedToPrimary() -> MultiCaretState {
        guard let primary = carets.first else { return MultiCaretState() }
        return MultiCaretState(caret: primary)
    }

    // MARK: - Normalization

    /// Normalizes an arbitrary caret list into document order without overlaps.
    ///
    /// Overlapping ranges collapse to the outermost bounding range. For
    /// example, `[0, 2)` and `[1, 4)` become `[0, 4)`. Insertion points at the
    /// same offset are duplicate carets and collapse to that single offset.
    /// Adjacent, non-overlapping carets (such as a selection ending at the
    /// same offset where another caret begins) are left separate.
    public static func normalized(_ carets: [NSRange]) -> [NSRange] {
        let cleaned = carets.compactMap { caret -> NSRange? in
            guard caret.location != NSNotFound else { return nil }
            return NSRange(location: max(0, caret.location), length: max(0, caret.length))
        }
        guard !cleaned.isEmpty else { return [] }

        let sorted = cleaned.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length > rhs.length
        }

        var result: [NSRange] = []
        for caret in sorted {
            guard let last = result.last else {
                result.append(caret)
                continue
            }

            // Sorted by location, so this caret can only overlap `last` on its
            // right edge. Equal locations are duplicate or nested carets.
            let overlaps = caret.location < last.upperBound || caret.location == last.location
            if overlaps {
                let start = min(last.location, caret.location)
                let end = max(last.upperBound, caret.upperBound)
                result[result.count - 1] = NSRange(location: start, length: end - start)
            } else {
                result.append(caret)
            }
        }
        return result
    }
}
