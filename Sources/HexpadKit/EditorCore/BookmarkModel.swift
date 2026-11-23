import Foundation

/// A bookmark on one logical line of a document.
///
/// Bookmarks are line-oriented, not range-oriented: they follow the line as
/// edits move it up or down and disappear when the line itself is deleted.
/// Lines are 1-based logical lines, matching ``GutterGeometry`` and the fold
/// model.
///
/// A bookmark's identity is its line. Two bookmarks on the same line cannot
/// coexist; the note is payload that moves with the line.
public struct Bookmark: Equatable, Hashable, Codable {

    /// 1-based logical line number in the document the bookmark belongs to.
    public let line: Int

    /// Optional note attached to the line. `nil` means "no note".
    public let note: String?

    public init(line: Int, note: String? = nil) {
        self.line = max(1, line)
        self.note = note
    }
}

/// The user's bookmarks, stored independently of any document text.
///
/// This is the persistence mirror of ``FoldState``: session save/restore and
/// the gutter layer can hold a `BookmarkState` while the text underneath is
/// replaced. Lines in the state are not required to exist in any particular
/// document; ``BookmarkModel`` validates them against the text it was built
/// with and drops lines that no longer exist.
///
/// `bookmarks` is always sorted by line and contains at most one bookmark per
/// line. Every mutating operation preserves that invariant, and decoded state
/// is normalized the same way.
public struct BookmarkState: Equatable, Codable {

    /// The bookmarks, sorted by ascending line, one per line.
    public private(set) var bookmarks: [Bookmark]

    public init(bookmarks: [Bookmark] = []) {
        self.bookmarks = BookmarkState.normalized(bookmarks)
    }

    /// Whether no line is bookmarked.
    public var isEmpty: Bool { bookmarks.isEmpty }

    /// Number of bookmarked lines.
    public var count: Int { bookmarks.count }

    /// The bookmarked line numbers in ascending order.
    public var lines: [Int] { bookmarks.map(\.line) }

    /// Whether `line` is bookmarked.
    public func isBookmarked(line: Int) -> Bool {
        bookmarks.contains { $0.line == line }
    }

    /// The bookmark on `line`, if any.
    public func bookmark(atLine line: Int) -> Bookmark? {
        bookmarks.first { $0.line == line }
    }

    /// The note attached to `line`, if the line is bookmarked and has a note.
    public func note(forLine line: Int) -> String? {
        bookmark(atLine: line)?.note
    }

    /// Adds `bookmark` when its line is not already bookmarked.
    ///
    /// - Returns: `true` when the bookmark was added.
    @discardableResult
    public mutating func add(_ bookmark: Bookmark) -> Bool {
        guard !isBookmarked(line: bookmark.line) else { return false }
        bookmarks = BookmarkState.normalized(bookmarks + [bookmark])
        return true
    }

    /// Bookmarks `line`, optionally attaching a note.
    ///
    /// - Returns: `true` when the line was not already bookmarked.
    @discardableResult
    public mutating func add(line: Int, note: String? = nil) -> Bool {
        add(Bookmark(line: line, note: note))
    }

    /// Removes the bookmark on `line`.
    ///
    /// - Returns: `true` when the line was bookmarked.
    @discardableResult
    public mutating func remove(line: Int) -> Bool {
        guard let index = bookmarks.firstIndex(where: { $0.line == line }) else { return false }
        bookmarks.remove(at: index)
        return true
    }

    /// Removes every bookmark.
    public mutating func removeAll() {
        bookmarks.removeAll()
    }

    /// Removes every bookmark. Alias for ``removeAll()``.
    public mutating func clear() {
        removeAll()
    }

    /// Adds `line` when absent, or removes it when present.
    ///
    /// - Parameter note: Note to attach when the bookmark is being added. An
    ///   existing note is not changed by a toggle that adds nothing.
    /// - Returns: `true` when the line is bookmarked afterwards.
    @discardableResult
    public mutating func toggle(line: Int, note: String? = nil) -> Bool {
        if isBookmarked(line: line) {
            remove(line: line)
            return false
        }
        add(line: line, note: note)
        return true
    }

    /// Replaces the note attached to `line`.
    ///
    /// - Returns: `true` when the line was bookmarked.
    @discardableResult
    public mutating func setNote(_ note: String?, forLine line: Int) -> Bool {
        guard let index = bookmarks.firstIndex(where: { $0.line == line }) else { return false }
        bookmarks[index] = Bookmark(line: line, note: note)
        return true
    }

    /// The next bookmark strictly after `line`, wrapping to the first.
    ///
    /// This is the Notepad++ behaviour: pressing "next bookmark" with the caret
    /// on a bookmark advances past it, and past the last bookmark wraps to the
    /// first. With a single bookmark the same bookmark is returned.
    public func next(afterLine line: Int) -> Bookmark? {
        bookmarks.first { $0.line > line } ?? bookmarks.first
    }

    /// The previous bookmark strictly before `line`, wrapping to the last.
    ///
    /// The mirror image of ``next(afterLine:)``.
    public func previous(beforeLine line: Int) -> Bookmark? {
        bookmarks.last { $0.line < line } ?? bookmarks.last
    }

    // MARK: - Edit remapping

    /// Remaps every bookmark across an edit, returning a new state.
    ///
    /// This is a pure function: the receiver is unchanged.
    ///
    /// The edit is expressed in pre-edit UTF-16 offsets, exactly like
    /// ``FoldTextEdit``, and `newText` is the document after the edit. Working
    /// from both texts means line shifts come from the actual line breaks
    /// inserted or removed, not from a heuristic on the character delta.
    ///
    /// - A bookmark whose line start is before the edit is unchanged when the
    ///   edit starts inside its line, and shifts when the edit is wholly above
    ///   the line.
    /// - An insertion at or before a line start shifts that line down by the
    ///   number of newlines inserted; an insertion inside the line leaves the
    ///   bookmark on the same line.
    /// - A deletion that covers the entire line span, including its terminator,
    ///   removes the bookmark. Deleting part of the line keeps the bookmark on
    ///   the surviving line.
    /// - Bookmarks whose remapped line falls outside `newText` are dropped.
    public func remapped(from oldText: String, for edit: FoldTextEdit, to newText: String) -> BookmarkState {
        guard !bookmarks.isEmpty else { return BookmarkState() }

        // One index per text instead of a full-buffer scan per bookmark and
        // per line lookup. LineIndex reproduces GutterGeometry's line math
        // exactly, so every mapping below keeps its old result.
        let oldIndex = LineIndex(oldText)
        let newIndex = LineIndex(newText)
        let oldLineCount = oldIndex.count
        let newLength = newIndex.textLength
        let newLineCount = newIndex.count
        let editEnd = edit.location + edit.replacedLength
        let oldLength = oldIndex.textLength

        var result: [Bookmark] = []
        for bookmark in bookmarks {
            guard bookmark.line >= 1, bookmark.line <= oldLineCount else { continue }

            let start = oldIndex.firstCharIndex(of: bookmark.line)
            let spanEnd = bookmark.line < oldLineCount
                ? oldIndex.firstCharIndex(of: bookmark.line + 1)
                : oldLength

            // A replacement or deletion that covers the complete line,
            // terminator included, deletes the line itself.
            if edit.replacedLength > 0,
               edit.location <= start,
               editEnd >= spanEnd {
                continue
            }

            let mappedStart: Int
            if edit.location > start {
                // The edit starts inside the line or after it; the line start
                // itself is untouched.
                mappedStart = start
            } else if edit.replacedLength == 0 {
                // Pure insertion at or before the line start pushes the line
                // down by whatever was inserted, matching fold remapping.
                mappedStart = start + edit.insertedLength
            } else if editEnd <= start {
                // The edit is wholly above the line.
                mappedStart = start + edit.delta
            } else {
                // The edit overlaps the line start. The surviving line content
                // begins immediately after the inserted text.
                mappedStart = edit.location + edit.insertedLength
            }

            let clamped = min(max(mappedStart, 0), newLength)
            let line = newIndex.line(of: clamped)
            guard line >= 1, line <= newLineCount else { continue }
            result.append(Bookmark(line: line, note: bookmark.note))
        }
        return BookmarkState(bookmarks: result)
    }

    // MARK: - Helpers

    /// Sorts by line and keeps the first bookmark for each line.
    static func normalized(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var seen = Set<Int>()
        var result: [Bookmark] = []
        for bookmark in bookmarks.sorted(by: { $0.line < $1.line }) where seen.insert(bookmark.line).inserted {
            result.append(bookmark)
        }
        return result
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case bookmarks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        self.init(bookmarks: decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bookmarks, forKey: .bookmarks)
    }
}

/// The bookmarks of one document, kept in step with its current text.
///
/// The model owns the document text only to answer line questions: which lines
/// exist, where a line starts, and which line survives an edit. Bookmark state
/// lives in a ``BookmarkState`` so a later session slice can persist it without
/// persisting the text.
///
/// Like ``FoldModel`` the model is pure and Kit-side. It has no `NSTextView`
/// dependency; the gutter margin and command layers consume it.
public struct BookmarkModel {

    /// The document text the bookmarks are valid against.
    public private(set) var text: String

    /// The bookmarks, persisted independently of the text.
    public private(set) var bookmarkState: BookmarkState

    /// Creates a model, dropping bookmarks on lines the text does not have.
    ///
    /// Restoring a state before the document is loaded is allowed; invalid
    /// lines are discarded rather than clamped, because a bookmark should never
    /// silently jump to an unrelated line.
    public init(text: String, bookmarkState: BookmarkState = BookmarkState()) {
        self.text = text
        // Nothing to validate: skip the document-wide line-count scan. This is
        // the common case on tab bind for documents the user never bookmarked.
        guard !bookmarkState.isEmpty else {
            self.bookmarkState = bookmarkState
            return
        }
        let lineCount = GutterGeometry.lineCount(in: text)
        self.bookmarkState = BookmarkState(
            bookmarks: bookmarkState.bookmarks.filter { $0.line <= lineCount }
        )
    }

    /// The bookmarks, sorted by line.
    public var bookmarks: [Bookmark] { bookmarkState.bookmarks }

    /// Number of bookmarked lines.
    public var count: Int { bookmarkState.count }

    /// Whether no line is bookmarked.
    public var isEmpty: Bool { bookmarkState.isEmpty }

    /// Number of logical lines in the current text.
    public var lineCount: Int { GutterGeometry.lineCount(in: text) }

    /// Whether `line` exists in the current text.
    public func isValid(line: Int) -> Bool {
        line >= 1 && line <= lineCount
    }

    /// Whether `line` is bookmarked.
    public func isBookmarked(line: Int) -> Bool {
        bookmarkState.isBookmarked(line: line)
    }

    /// The bookmark on `line`, if any.
    public func bookmark(atLine line: Int) -> Bookmark? {
        bookmarkState.bookmark(atLine: line)
    }

    /// The note attached to `line`, if any.
    public func note(forLine line: Int) -> String? {
        bookmarkState.note(forLine: line)
    }

    /// Bookmarks `line`, optionally attaching a note.
    ///
    /// - Returns: `true` when the line exists and was not already bookmarked.
    @discardableResult
    public mutating func add(line: Int, note: String? = nil) -> Bool {
        guard isValid(line: line) else { return false }
        return bookmarkState.add(line: line, note: note)
    }

    /// Removes the bookmark on `line`.
    ///
    /// - Returns: `true` when the line was bookmarked.
    @discardableResult
    public mutating func remove(line: Int) -> Bool {
        bookmarkState.remove(line: line)
    }

    /// Removes every bookmark.
    public mutating func removeAll() {
        bookmarkState.removeAll()
    }

    /// Removes every bookmark. Alias for ``removeAll()``.
    public mutating func clear() {
        bookmarkState.removeAll()
    }

    /// Adds `line` when absent, or removes it when present.
    ///
    /// - Returns: `true` when the line is bookmarked afterwards. A line outside
    ///   the document cannot be toggled.
    @discardableResult
    public mutating func toggle(line: Int, note: String? = nil) -> Bool {
        if bookmarkState.isBookmarked(line: line) {
            bookmarkState.remove(line: line)
            return false
        }
        guard isValid(line: line) else { return false }
        bookmarkState.add(line: line, note: note)
        return true
    }

    /// Replaces the note attached to `line`.
    ///
    /// - Returns: `true` when the line was bookmarked.
    @discardableResult
    public mutating func setNote(_ note: String?, forLine line: Int) -> Bool {
        bookmarkState.setNote(note, forLine: line)
    }

    /// The next bookmark strictly after `line`, wrapping to the first.
    public func next(afterLine line: Int) -> Bookmark? {
        bookmarkState.next(afterLine: line)
    }

    /// The previous bookmark strictly before `line`, wrapping to the last.
    public func previous(beforeLine line: Int) -> Bookmark? {
        bookmarkState.previous(beforeLine: line)
    }

    // MARK: - Remapping

    /// Remaps the bookmarks across an edit, returning a new state.
    ///
    /// Pure: the receiver's text and bookmarks are unchanged.
    public func remappedState(for edit: FoldTextEdit, in newText: String) -> BookmarkState {
        bookmarkState.remapped(from: text, for: edit, to: newText)
    }

    /// Remaps the bookmarks across an edit, returning a new model over
    /// `newText`.
    public func remapped(for edit: FoldTextEdit, in newText: String) -> BookmarkModel {
        BookmarkModel(text: newText, bookmarkState: remappedState(for: edit, in: newText))
    }

    /// Applies an edit: remaps the bookmarks and adopts `newText`.
    public mutating func remap(for edit: FoldTextEdit, in newText: String) {
        bookmarkState = remappedState(for: edit, in: newText)
        text = newText
    }

    /// Adopts `newText` without an edit, keeping only bookmarks on lines that
    /// still exist.
    ///
    /// Use this for changes that are not a single text edit, such as reloading
    /// a file from disk.
    public mutating func updateText(_ newText: String) {
        text = newText
        let lineCount = GutterGeometry.lineCount(in: newText)
        bookmarkState = BookmarkState(
            bookmarks: bookmarkState.bookmarks.filter { $0.line <= lineCount }
        )
    }

    /// The state revalidated against `newText`, dropping lines that no longer
    /// exist.
    public func revalidatedState(in newText: String) -> BookmarkState {
        let lineCount = GutterGeometry.lineCount(in: newText)
        return BookmarkState(bookmarks: bookmarkState.bookmarks.filter { $0.line <= lineCount })
    }
}
