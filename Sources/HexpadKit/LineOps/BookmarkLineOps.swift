import Foundation

/// Whole-line operations driven by the document's bookmarks.
///
/// Notepad++'s Search > Bookmark group works on the complete logical lines
/// that carry a bookmark, in document order. These operations are pure: they
/// take the current text, selection and ``BookmarkState`` and return the text,
/// selection and bookmark state for the caller to apply as one undoable edit.
///
/// Clipboard-bearing operations return the payload instead of touching
/// `NSPasteboard`, keeping the Kit free of AppKit. The app layer writes the
/// payload and supplies clipboard text when pasting.
///
/// The editor's buffer is LF-only (the document's EOL setting is save
/// metadata), so copied lines are always newline-terminated with `"\n"`.
public struct BookmarkLineOps {

    /// The result of one bookmarked-line operation.
    ///
    /// `clipboardText` is the new pasteboard payload for Cut and Copy and
    /// `nil` for operations that leave the clipboard alone.
    public struct Result: Equatable {

        /// The document text after the operation.
        public var text: String

        /// The UTF-16 selection to restore.
        public var selection: NSRange

        /// The bookmarks after the operation.
        public var bookmarks: BookmarkState

        /// Pasteboard payload to write, if the operation changed it.
        public var clipboardText: String?

        public init(text: String,
                    selection: NSRange,
                    bookmarks: BookmarkState,
                    clipboardText: String? = nil) {
            self.text = text
            self.selection = selection
            self.bookmarks = bookmarks
            self.clipboardText = clipboardText
        }
    }

    // MARK: - Copy

    /// Copies every bookmarked line to the clipboard payload, each line
    /// newline-terminated, and leaves the document untouched.
    ///
    /// With no bookmarks the result is unchanged and `clipboardText` is `nil`.
    public static func copy(_ text: String,
                            selection: NSRange,
                            bookmarks: BookmarkState) -> Result {
        let ns = text as NSString
        let clamped = clamp(selection, in: ns)
        let marked = markedLines(in: text, bookmarks: bookmarks)
        guard !marked.isEmpty else {
            return Result(text: text, selection: clamped, bookmarks: bookmarks)
        }
        return Result(text: text,
                      selection: clamped,
                      bookmarks: bookmarks,
                      clipboardText: copiedText(for: marked, in: text))
    }

    // MARK: - Cut / Remove

    /// Removes every bookmarked line and returns those lines as the clipboard
    /// payload.
    ///
    /// The removed lines' bookmarks disappear with them. Because every
    /// bookmarked line is removed, the resulting bookmark state is empty.
    public static func cut(_ text: String,
                           selection: NSRange,
                           bookmarks: BookmarkState) -> Result {
        var result = remove(text, selection: selection, bookmarks: bookmarks)
        let marked = markedLines(in: text, bookmarks: bookmarks)
        if !marked.isEmpty {
            result.clipboardText = copiedText(for: marked, in: text)
        }
        return result
    }

    /// Removes every bookmarked line without touching the clipboard.
    ///
    /// The removed lines' bookmarks disappear with them, so the resulting
    /// bookmark state is empty.
    public static func remove(_ text: String,
                              selection: NSRange,
                              bookmarks: BookmarkState) -> Result {
        let ns = text as NSString
        let clamped = clamp(selection, in: ns)
        let marked = markedLines(in: text, bookmarks: bookmarks)
        guard !marked.isEmpty else {
            return Result(text: text, selection: clamped, bookmarks: bookmarks)
        }

        let spans = removalSpans(for: marked, in: text)
        let mutable = NSMutableString(string: text)
        for span in spans.reversed() {
            mutable.replaceCharacters(in: span, with: "")
        }

        let newLength = mutable.length
        let start = map(clamped.location, throughRemovals: spans)
        let end = map(clamped.location + clamped.length, throughRemovals: spans)
        let selectionStart = min(max(0, start), newLength)
        let selectionEnd = min(max(selectionStart, end), newLength)

        return Result(text: mutable as String,
                      selection: NSRange(location: selectionStart,
                                         length: selectionEnd - selectionStart),
                      bookmarks: BookmarkState())
    }

    // MARK: - Paste to replace

    /// Replaces the content of bookmarked lines with the clipboard's lines.
    ///
    /// The i-th bookmarked line receives the i-th clipboard line, in document
    /// order. Extra clipboard lines are ignored; when the clipboard runs out
    /// the remaining bookmarked lines keep their original content. The
    /// bookmarks themselves stay on their lines.
    ///
    /// Clipboard line endings are normalised to `"\n"` because the buffer is
    /// LF-only. A single trailing newline is treated as the terminator of the
    /// last clipboard line, not as an extra empty line, while an empty
    /// clipboard is a no-op.
    public static func pasteReplacing(_ text: String,
                                      selection: NSRange,
                                      bookmarks: BookmarkState,
                                      clipboard: String) -> Result {
        let ns = text as NSString
        let clamped = clamp(selection, in: ns)
        let marked = markedLines(in: text, bookmarks: bookmarks)
        let lines = clipboardLines(clipboard)
        guard !marked.isEmpty, !lines.isEmpty else {
            return Result(text: text, selection: clamped, bookmarks: bookmarks)
        }

        let spans = lineSpans(in: text)
        var edits: [TextEdit] = []
        for (index, lineNumber) in marked.enumerated() where index < lines.count {
            edits.append(TextEdit(range: spans[lineNumber - 1].content,
                                  replacement: lines[index]))
        }
        guard !edits.isEmpty else {
            return Result(text: text, selection: clamped, bookmarks: bookmarks)
        }

        let mutable = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }

        let newLength = mutable.length
        let start = map(clamped.location, through: edits)
        let end = map(clamped.location + clamped.length, through: edits)
        let selectionStart = min(max(0, start), newLength)
        let selectionEnd = min(max(selectionStart, end), newLength)

        return Result(text: mutable as String,
                      selection: NSRange(location: selectionStart,
                                         length: selectionEnd - selectionStart),
                      bookmarks: bookmarks)
    }

    // MARK: - Inverse

    /// Inverts which lines are bookmarked: bookmarked lines lose their
    /// bookmark and every other line gains one.
    ///
    /// The total count becomes `lineCount - bookmarkCount`, so it is preserved
    /// exactly when the document was half bookmarked. An empty document is a
    /// no-op because there is no line to bookmark.
    public static func inverse(_ text: String,
                               selection: NSRange,
                               bookmarks: BookmarkState) -> Result {
        let ns = text as NSString
        let clamped = clamp(selection, in: ns)
        guard !text.isEmpty else {
            return Result(text: text, selection: clamped, bookmarks: bookmarks)
        }

        let lineCount = GutterGeometry.lineCount(in: text)
        var inverted: [Bookmark] = []
        for line in 1...lineCount where !bookmarks.isBookmarked(line: line) {
            inverted.append(Bookmark(line: line))
        }
        return Result(text: text,
                      selection: clamped,
                      bookmarks: BookmarkState(bookmarks: inverted))
    }

    // MARK: - Line geometry

    /// A logical line's full range (terminator included) and content range.
    private struct LineSpan {
        let full: NSRange
        let content: NSRange
    }

    /// One replacement in original document coordinates.
    private struct TextEdit {
        let range: NSRange
        let replacement: String

        var insertedLength: Int { (replacement as NSString).length }
    }

    /// The bookmarked line numbers that exist in `text`, in ascending order.
    private static func markedLines(in text: String, bookmarks: BookmarkState) -> [Int] {
        let lineCount = GutterGeometry.lineCount(in: text)
        return bookmarks.bookmarks
            .map(\.line)
            .filter { $0 >= 1 && $0 <= lineCount }
    }

    /// Splits `text` into logical lines using the same LF-based geometry as
    /// the bookmark model, so line numbers always agree with the gutter.
    private static func lineSpans(in text: String) -> [LineSpan] {
        let ns = text as NSString
        let lineCount = GutterGeometry.lineCount(in: text)
        var spans: [LineSpan] = []
        spans.reserveCapacity(lineCount)
        for line in 1...lineCount {
            let start = GutterGeometry.firstCharIndex(of: line, in: text)
            let end: Int
            if line < lineCount {
                end = GutterGeometry.firstCharIndex(of: line + 1, in: text)
            } else {
                end = ns.length
            }
            var contentsEnd = end
            if contentsEnd > start, ns.character(at: contentsEnd - 1) == 0x0A {
                contentsEnd -= 1
            }
            if contentsEnd > start, ns.character(at: contentsEnd - 1) == 0x0D {
                contentsEnd -= 1
            }
            spans.append(LineSpan(full: NSRange(location: start, length: end - start),
                                  content: NSRange(location: start, length: contentsEnd - start)))
        }
        return spans
    }

    /// Merged deletion ranges for runs of consecutive bookmarked lines.
    ///
    /// When a run ends with the final line and that line has no terminator,
    /// the preceding line ending is included so deleting the last line does
    /// not leave a dangling blank line (matching ``LineOps/deleteLine``).
    private static func removalSpans(for lines: [Int], in text: String) -> [NSRange] {
        let spans = lineSpans(in: text)
        var result: [NSRange] = []

        var runStart = lines[0]
        var previous = lines[0]
        func appendRun(start: Int, end: Int) {
            let first = spans[start - 1]
            let last = spans[end - 1]
            var location = first.full.location
            let runEnd = last.full.upperBound
            if last.full.length == last.content.length, location > 0 {
                location -= precedingLineEndingLength(before: location, in: text as NSString)
            }
            result.append(NSRange(location: location, length: runEnd - location))
        }

        for line in lines.dropFirst() {
            if line == previous + 1 {
                previous = line
            } else {
                appendRun(start: runStart, end: previous)
                runStart = line
                previous = line
            }
        }
        appendRun(start: runStart, end: previous)
        return result
    }

    /// Length of the line ending immediately before `location` (LF-only buffer,
    /// with a defensive CRLF case).
    private static func precedingLineEndingLength(before location: Int, in text: NSString) -> Int {
        guard location > 0, location <= text.length else { return 0 }
        guard text.character(at: location - 1) == 0x0A else { return 0 }
        if location >= 2, text.character(at: location - 2) == 0x0D {
            return 2
        }
        return 1
    }

    /// The copied representation of bookmarked lines: content plus `"\n"` for
    /// each line, in document order.
    private static func copiedText(for lines: [Int], in text: String) -> String {
        let ns = text as NSString
        let spans = lineSpans(in: text)
        var copied = ""
        for line in lines {
            copied += ns.substring(with: spans[line - 1].content)
            copied += "\n"
        }
        return copied
    }

    // MARK: - Clipboard

    /// Clipboard text as LF-only logical lines.
    ///
    /// A trailing newline is treated as the last line's terminator, so copying
    /// and then pasting N lines moves N lines. `""` means "nothing to paste".
    private static func clipboardLines(_ clipboard: String) -> [String] {
        guard !clipboard.isEmpty else { return [] }
        var normalized = clipboard.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    // MARK: - Offset mapping

    private static func clamp(_ selection: NSRange, in text: NSString) -> NSRange {
        guard selection.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(selection.location, text.length))
        let length = max(0, min(selection.length, text.length - location))
        return NSRange(location: location, length: length)
    }

    /// Maps one pre-edit offset through merged deletion ranges.
    private static func map(_ offset: Int, throughRemovals spans: [NSRange]) -> Int {
        var removedBefore = 0
        for span in spans {
            if offset >= span.upperBound {
                removedBefore += span.length
            } else if offset > span.location {
                return span.location - removedBefore
            } else {
                break
            }
        }
        return offset - removedBefore
    }

    /// Maps one pre-edit offset through content replacements.
    ///
    /// An offset inside replaced content collapses to the replacement's start;
    /// offsets after a replacement move by its length delta.
    private static func map(_ offset: Int, through edits: [TextEdit]) -> Int {
        var delta = 0
        for edit in edits {
            if offset >= edit.range.upperBound {
                delta += edit.insertedLength - edit.range.length
            } else if offset > edit.range.location {
                return edit.range.location + delta
            } else {
                break
            }
        }
        return offset + delta
    }
}
