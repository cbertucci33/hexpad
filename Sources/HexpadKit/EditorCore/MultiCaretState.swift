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

/// Pure model for the Search > Multi-select commands.
///
/// ``MultiCaretState`` keeps the carets themselves in document order with
/// overlaps collapsed. The N++ commands need two extra pieces of bookkeeping a
/// caret set cannot express: the order carets were added in (for "Undo Latest
/// Multi-select") and the occurrences the user explicitly skipped (so "Skip
/// Current and Go to Next" never selects one again). This value holds all three
/// and exposes one mutating entry point per command. It is deliberately Kit-side
/// and AppKit-free so the semantics are testable headlessly.
///
/// Match ranges are UTF-16 `NSRange`s in document order, as returned by
/// ``SearchEngine/search(_:pattern:options:range:)``. Callers refresh them on
/// every command; this type never touches the document text.
public struct MultiSelectState: Equatable {

    /// The live carets, always normalized by ``MultiCaretState``.
    public private(set) var carets: MultiCaretState

    /// The collected matches for the current query, in document order.
    public private(set) var matches: [NSRange]

    /// Carets in the order the user added them. The last element is "current".
    public private(set) var addOrder: [NSRange]

    /// Occurrences dropped by Skip Current, excluded from later selection.
    public private(set) var skipped: [NSRange]

    public init(carets: MultiCaretState = MultiCaretState(),
                matches: [NSRange] = [],
                addOrder: [NSRange] = [],
                skipped: [NSRange] = []) {
        self.carets = carets
        self.matches = matches
        self.addOrder = addOrder
        self.skipped = skipped
    }

    /// Replaces the collected match set without disturbing the caret set or its
    /// add-order / skip bookkeeping. Call this before each command so a changed
    /// query or buffer is reflected in the next pick.
    public mutating func updateMatches(_ newMatches: [NSRange]) {
        matches = newMatches
    }

    /// Every match becomes a caret. The resulting set is in document order with
    /// overlaps collapsed by ``MultiCaretState``.
    ///
    /// Returns `false` (a no-op) when the match set is empty or already exactly
    /// the current caret set. Add order is reset to the resulting carets, so a
    /// following Undo Latest removes the bottom-most one.
    @discardableResult
    public mutating func selectAllOccurrences() -> Bool {
        guard !matches.isEmpty else { return false }
        let result = MultiCaretState(carets: matches)
        guard result != carets else { return false }
        carets = result
        addOrder = result.carets
        skipped = []
        return true
    }

    /// Adds the next match after the most recently added caret as a new caret.
    ///
    /// The anchor is `addOrder.last`, falling back to the primary caret when
    /// nothing was added this session. Already-selected and skipped matches are
    /// excluded. There is deliberately no wrap: at the document end the command
    /// is a no-op.
    @discardableResult
    public mutating func selectNext() -> Bool {
        guard let anchor = addOrder.last ?? carets.primaryCaret else { return false }
        let excluded = carets.carets + skipped
        guard let index = SearchEngine.nextMatchIndex(from: anchor.location,
                                                       in: matches,
                                                       excluding: excluded) else { return false }
        let next = matches[index]
        var result = carets
        result.addCaret(next)
        guard result != carets else { return false }
        carets = result
        reconcileAddOrder()
        addOrder.append(concreteCaret(for: next) ?? next)
        return true
    }

    /// Drops the current (most recently added) caret, marks its match skipped,
    /// and adds the following match in its place.
    ///
    /// The skipped occurrence is recorded before the pick, so it can never be
    /// re-added by a later Next or Skip. When there is no following match the
    /// current caret is still removed, matching N++'s "skip" half of the
    /// command; Undo Latest can bring it back.
    @discardableResult
    public mutating func skipCurrentAndGoToNext() -> Bool {
        guard let current = addOrder.last ?? carets.primaryCaret else { return false }
        let before = carets
        var result = carets
        result.removeCaret(current)
        skipped.append(current)

        let excluded = result.carets + skipped
        if let index = SearchEngine.nextMatchIndex(from: current.upperBound,
                                                     in: matches,
                                                     excluding: excluded) {
            let next = matches[index]
            result.addCaret(next)
            carets = result
            reconcileAddOrder()
            addOrder.append(concreteCaret(for: next) ?? next)
        } else {
            carets = result
            reconcileAddOrder()
        }
        return carets != before
    }

    /// Removes the most recently added caret. Returns `false` when nothing was
    /// added this session. Skipped occurrences stay skipped: undo reverses the
    /// caret, not the user's explicit skip.
    @discardableResult
    public mutating func undoLatest() -> Bool {
        guard let last = addOrder.popLast() else { return false }
        var result = carets
        result.removeCaret(last)
        carets = result
        reconcileAddOrder()
        return true
    }

    // MARK: - Add-order bookkeeping

    /// Maps each stored add-order range onto the exact caret now in the set.
    ///
    /// ``MultiCaretState`` merges overlapping ranges, so an added caret can end
    /// up folded into a larger one. Without this pass Undo Latest would try to
    /// remove a range that no longer exists verbatim.
    private mutating func reconcileAddOrder() {
        addOrder = addOrder.compactMap { concreteCaret(for: $0) }
    }

    private func concreteCaret(for range: NSRange) -> NSRange? {
        if carets.carets.contains(range) { return range }
        return carets.carets.first { caret in
            NSLocationInRange(range.location, caret)
                || NSLocationInRange(caret.location, NSRange(location: range.location,
                                                              length: max(0, range.length)))
        }
    }
}

/// The anchored half of a Search > Begin/End Select cycle.
///
/// The editor keeps one pending anchor per view, but the toggle semantics are
/// pure and live here so they can be tested without AppKit. `range` is the
/// UTF-16 selection that was anchored: an empty range for a bare caret, or the
/// whole selection when the command was invoked with text already selected
/// (Notepad++ anchors that range). `point` is the same position expressed as a
/// `TextPoint`, because the column variant needs a rectangle rather than a
/// linear range. `columnMode` records which command began the cycle; a mixed
/// completing press completes with the mode the cycle started in.
public struct BeginEndSelectAnchor: Equatable {

    /// The anchored UTF-16 selection (empty for a bare caret).
    public var range: NSRange

    /// The anchored caret as a line/column point.
    public var point: TextPoint

    /// Whether the cycle began in column mode.
    public var columnMode: Bool

    public init(range: NSRange, point: TextPoint, columnMode: Bool) {
        self.range = range
        self.point = point
        self.columnMode = columnMode
    }
}

/// The selection a completing Begin/End Select press asks the editor to apply.
public enum BeginEndSelectCompletion: Equatable {

    /// A normal contiguous selection, from the anchored range to the caret.
    case range(NSRange)

    /// A column selection, as the two corners of a ``ColumnRectangle``. The
    /// app maps these through ``ColumnEditing/carets(in:rectangle:)`` into the
    /// same `MultiCaretState` used by every other column operation.
    case column(TextPoint, TextPoint)
}

/// Pure anchor state for the Search > Begin/End Select toggle pair.
///
/// First press (``begin(selection:point:columnMode:)``) stores the anchor;
/// second press (``complete(selection:point:)``) returns the selection to apply
/// and clears the anchor. A completing press with no pending anchor is a no-op
/// (`nil`) — notably, the app keeps the menu item enabled in that case, exactly
/// as Notepad++ does. The editor cancels a pending anchor on any selection
/// change not caused by the command itself (``cancel()``).
public struct BeginEndSelectState: Equatable {

    /// The pending anchor, or `nil` when no cycle is in progress.
    public private(set) var anchor: BeginEndSelectAnchor?

    public init() {}

    /// Anchors the current selection/caret. Invoking Begin while an anchor is
    /// already pending replaces it, which is what a re-armed toggle does.
    public mutating func begin(selection: NSRange, point: TextPoint, columnMode: Bool) {
        anchor = BeginEndSelectAnchor(range: selection,
                                      point: point,
                                      columnMode: columnMode)
    }

    /// Completes the cycle from the anchor to `selection`, or no-ops (`nil`)
    /// when nothing is pending. The anchor is consumed either way it completes.
    @discardableResult
    public mutating func complete(selection: NSRange,
                                  point: TextPoint) -> BeginEndSelectCompletion? {
        guard let anchor else { return nil }
        self.anchor = nil
        if anchor.columnMode {
            return .column(anchor.point, point)
        }
        return .range(NSUnionRange(anchor.range, selection))
    }

    /// One menu press: begin when idle, complete when an anchor is pending.
    /// Returns `nil` for the Begin half because it changes no selection.
    @discardableResult
    public mutating func toggle(selection: NSRange,
                                point: TextPoint,
                                columnMode: Bool) -> BeginEndSelectCompletion? {
        guard anchor != nil else {
            begin(selection: selection, point: point, columnMode: columnMode)
            return nil
        }
        return complete(selection: selection, point: point)
    }

    /// Notepad++ parity: any selection change not caused by Begin/End Select
    /// (mouse, arrow keys, find navigation, tab switch) cancels the anchor.
    public mutating func cancel() {
        anchor = nil
    }
}
