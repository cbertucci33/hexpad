import Foundation

// MARK: - Session persistence

extension BookmarkState {

    /// JSON-ready projection of the bookmarks, nested under a single
    /// `bookmarkState` key in the document's session dictionary.
    ///
    /// The projection stores only 1-based logical line numbers and notes, not
    /// text, so its shape is independent of the document's contents. Restoring
    /// a state whose lines no longer match the text is the app layer's concern:
    /// the lines are carried verbatim and `BookmarkModel` decides what is still
    /// usable against the current document.
    ///
    /// Entries are sorted by line so repeated saves of the same state produce
    /// byte-identical session data. A bookmark without a note omits the `note`
    /// key rather than writing a null, so `nil` and "no note written" restore
    /// identically.
    func toSessionData() -> [String: Any] {
        let bookmarks: [[String: Any]] = self.bookmarks
            .sorted { $0.line < $1.line }
            .map { bookmark in
                var entry: [String: Any] = ["line": bookmark.line]
                if let note = bookmark.note {
                    entry["note"] = note
                }
                return entry
            }
        return ["bookmarks": bookmarks]
    }

    /// Restores a state written by ``toSessionData()``.
    ///
    /// A session written before bookmark persistence existed has no
    /// `bookmarkState` key and restores as an empty state. Malformed entries are
    /// skipped individually rather than discarding the whole state: a missing or
    /// non-positive line, or a present-but-non-string note, is ignored. A future
    /// build's extra keys are ignored silently.
    static func fromSessionData(_ data: [String: Any]?) -> BookmarkState {
        guard let data,
              let entries = data["bookmarks"] as? [[String: Any]] else {
            return BookmarkState()
        }

        var bookmarks: [Bookmark] = []
        for entry in entries {
            guard let line = intValue(entry["line"]), line >= 1 else {
                continue
            }
            let note: String?
            if let rawNote = entry["note"] {
                guard let string = rawNote as? String else { continue }
                note = string
            } else {
                note = nil
            }
            bookmarks.append(Bookmark(line: line, note: note))
        }
        // `BookmarkState` sorts by line and keeps one bookmark per line, so the
        // restored value follows the same invariants as an edited state.
        return BookmarkState(bookmarks: bookmarks)
    }

    // JSONSerialization hands numbers back as NSNumber; tests and callers may
    // also supply native Swift numbers. Accept both.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}
