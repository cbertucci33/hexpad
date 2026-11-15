import Foundation

/// A zero-based line/column position in a document.
///
/// Lines are logical lines: a line ending (`\n`, `\r\n` or `\r`) separates two
/// lines but never counts as part of either one. Columns are UTF-16 code-unit
/// offsets from the start of a line's content, which means a tab counts as one
/// column and an emoji counts as two.
public struct TextPoint: Equatable {

    /// Zero-based logical line index.
    public var line: Int

    /// Zero-based UTF-16 column within the line's content.
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// How a rectangular selection treats lines that are shorter than the
/// rectangle.
public enum ColumnRaggedLinePolicy: Equatable {

    /// Short lines still receive a caret. A line that ends before the
    /// rectangle's first column gets a zero-length caret at its end of line;
    /// a line that starts before the rectangle but ends inside it gets a caret
    /// truncated at its end of line.
    ///
    /// This is the default and matches the way column selections behave in
    /// editors such as Notepad++ when "column selection to end of line" is
    /// enabled.
    case clampToEndOfLine

    /// Lines that do not reach the rectangle's first column are omitted.
    ///
    /// Partially covered lines are still included, clamped at their end of
    /// line. Use this when a column edit must not append text to shorter
    /// lines.
    case skipShortLines
}

/// A rectangular (column) region expressed as two caret points.
///
/// The two corners may be given in any order: ``lineRange`` and
/// ``columnRange`` normalize them into ascending order. A rectangle whose
/// corners share a line is a normal linear selection; a rectangle whose corners
/// share a column is a zero-width column of insertion points.
public struct ColumnRectangle: Equatable {

    /// One corner of the rectangle.
    public var start: TextPoint

    /// The opposite corner of the rectangle.
    public var end: TextPoint

    /// How lines shorter than the rectangle are handled.
    public var raggedLinePolicy: ColumnRaggedLinePolicy

    public init(start: TextPoint,
                end: TextPoint,
                raggedLinePolicy: ColumnRaggedLinePolicy = .clampToEndOfLine) {
        self.start = start
        self.end = end
        self.raggedLinePolicy = raggedLinePolicy
    }

    /// The inclusive range of lines touched by the rectangle.
    public var lineRange: ClosedRange<Int> {
        min(start.line, end.line)...max(start.line, end.line)
    }

    /// The half-open range of columns touched by the rectangle.
    ///
    /// When both corners share a column this is an empty range positioned at
    /// that column.
    public var columnRange: Range<Int> {
        let lower = min(start.column, end.column)
        let upper = max(start.column, end.column)
        return lower..<upper
    }

    /// Whether both corners are on the same line.
    public var isSingleLine: Bool { start.line == end.line }

    /// Whether both corners are in the same column.
    public var isSingleColumn: Bool { start.column == end.column }
}

/// Pure column-mode editing over a document and a multi-caret state.
///
/// This type contains no `NSTextView` or app-layer code: callers hand it a
/// string plus a ``ColumnRectangle`` (or an explicit ``MultiCaretState``) and
/// receive the transformed string and carets. Applying a result to a text view
/// as a single undoable replacement is left to a later, view-side slice.
///
/// A rectangular selection is represented by an ordinary ``MultiCaretState``:
/// one caret per line, each spanning the rectangle's column span. The existing
/// ``MultiCaretApplier`` then performs edits bottom-up so offsets stay valid.
public enum ColumnEditing {

    // MARK: - Line geometry

    /// One logical line of a document.
    ///
    /// ``contentRange`` excludes the line terminator, so its length is also the
    /// line's column count. ``fullRange`` includes the terminator. A document
    /// always has at least one line; a trailing line ending therefore produces
    /// a final empty line, just like a text editor would display.
    public struct LogicalLine: Equatable {

        /// The line's content, excluding its terminator.
        public let contentRange: NSRange

        /// The terminator's UTF-16 length: 2 for `\r\n`, 1 for `\n`, `\r`,
        /// U+0085, U+2028 and U+2029, and 0 for the final line of a document
        /// that does not end with a line ending.
        public let terminatorLength: Int

        public init(contentRange: NSRange, terminatorLength: Int) {
            self.contentRange = contentRange
            self.terminatorLength = terminatorLength
        }

        /// The number of addressable columns in this line.
        public var columnCount: Int { contentRange.length }

        /// The line's full range, including its terminator.
        public var fullRange: NSRange {
            NSRange(location: contentRange.location,
                    length: contentRange.length + terminatorLength)
        }
    }

    /// Splits `text` into logical lines.
    ///
    /// `\r\n` is consumed as one terminator, so columns are always measured
    /// against the line's content rather than raw bytes.
    public static func lines(in text: String) -> [LogicalLine] {
        let document = text as NSString
        let length = document.length

        var result: [LogicalLine] = []
        var lineStart = 0
        var index = 0

        while index < length {
            let character = document.character(at: index)
            let terminatorLength: Int

            if character == 0x000D {
                if index + 1 < length, document.character(at: index + 1) == 0x000A {
                    terminatorLength = 2
                } else {
                    terminatorLength = 1
                }
            } else if character == 0x000A || character == 0x0085
                        || character == 0x2028 || character == 0x2029 {
                terminatorLength = 1
            } else {
                index += 1
                continue
            }

            result.append(LogicalLine(
                contentRange: NSRange(location: lineStart, length: index - lineStart),
                terminatorLength: terminatorLength
            ))
            index += terminatorLength
            lineStart = index
        }

        result.append(LogicalLine(
            contentRange: NSRange(location: lineStart, length: length - lineStart),
            terminatorLength: 0
        ))
        return result
    }

    // MARK: - Building a column selection

    /// Builds the carets for a rectangular region.
    ///
    /// The result contains one caret per line touched by the rectangle. Each
    /// caret spans the rectangle's column range, clamped to the line's content,
    /// and is returned in document order by ``MultiCaretState``.
    ///
    /// - Parameters:
    ///   - text: The document the rectangle refers to.
    ///   - rectangle: The line/column region to convert.
    /// - Returns: A multi-caret state, or an empty state when the rectangle
    ///   lies entirely outside the document or every line is skipped by
    ///   ``ColumnRaggedLinePolicy/skipShortLines``.
    public static func carets(in text: String,
                              rectangle: ColumnRectangle) -> MultiCaretState {
        carets(in: text,
               from: rectangle.start,
               to: rectangle.end,
               raggedLinePolicy: rectangle.raggedLinePolicy)
    }

    /// Builds the carets for a rectangular region given its two corners.
    ///
    /// This is a convenience equivalent to constructing a ``ColumnRectangle``
    /// and calling ``carets(in:rectangle:)``.
    public static func carets(in text: String,
                              from start: TextPoint,
                              to end: TextPoint,
                              raggedLinePolicy: ColumnRaggedLinePolicy = .clampToEndOfLine) -> MultiCaretState {
        let documentLines = lines(in: text)
        guard !documentLines.isEmpty else { return MultiCaretState() }

        let firstLine = max(0, min(start.line, end.line))
        let lastLine = min(documentLines.count - 1, max(start.line, end.line))
        guard firstLine <= lastLine else { return MultiCaretState() }

        let lowerColumn = max(0, min(start.column, end.column))
        let upperColumn = max(lowerColumn, max(start.column, end.column))

        var carets: [NSRange] = []
        for lineIndex in firstLine...lastLine {
            let line = documentLines[lineIndex]
            let lineLength = line.columnCount

            // A line that cannot reach the rectangle's first column has no
            // characters to cover. The caller chooses whether it still gets an
            // end-of-line caret or is left alone.
            if raggedLinePolicy == .skipShortLines && lineLength < lowerColumn {
                continue
            }

            let startColumn = min(lowerColumn, lineLength)
            let endColumn = min(upperColumn, lineLength)
            carets.append(NSRange(location: line.contentRange.location + startColumn,
                                  length: max(0, endColumn - startColumn)))
        }

        return MultiCaretState(carets: carets)
    }

    // MARK: - Column operations

    /// Inserts `insertion` at every caret.
    ///
    /// A zero-length caret becomes a plain insertion. A caret with a length
    /// (for example one produced from a ``ColumnRectangle``) is replaced by
    /// `insertion`, matching typing over a selection. The returned carets sit
    /// immediately after each insertion.
    public static func insert(_ insertion: String,
                              into text: String,
                              state: MultiCaretState) -> (text: String, state: MultiCaretState) {
        MultiCaretApplier.apply(insertionTransform(insertion), to: text, state: state)
    }

    /// Builds the rectangle's carets and inserts `insertion` at each one.
    public static func insert(_ insertion: String,
                              into text: String,
                              rectangle: ColumnRectangle) -> (text: String, state: MultiCaretState) {
        insert(insertion, into: text, state: carets(in: text, rectangle: rectangle))
    }

    /// Deletes every caret's range.
    ///
    /// With the carets produced by ``carets(in:rectangle:)`` this removes the
    /// rectangular region. Zero-length carets are no-ops. The returned state
    /// contains a caret at each deletion point.
    public static func delete(in text: String,
                              state: MultiCaretState) -> (text: String, state: MultiCaretState) {
        MultiCaretApplier.apply(deletionTransform, to: text, state: state)
    }

    /// Builds the rectangle's carets and deletes the rectangular region.
    public static func delete(in text: String,
                              rectangle: ColumnRectangle) -> (text: String, state: MultiCaretState) {
        delete(in: text, state: carets(in: text, rectangle: rectangle))
    }

    /// Applies any ``MultiCaretApplier`` transform, such as a `LineOps`
    /// operation, at every caret in `state`.
    public static func apply(_ transform: MultiCaretApplier.TextTransform,
                             to text: String,
                             state: MultiCaretState) -> (text: String, state: MultiCaretState) {
        MultiCaretApplier.apply(transform, to: text, state: state)
    }

    /// Builds the rectangle's carets and applies `transform` at each one.
    public static func apply(_ transform: MultiCaretApplier.TextTransform,
                             to text: String,
                             rectangle: ColumnRectangle) -> (text: String, state: MultiCaretState) {
        apply(transform, to: text, state: carets(in: text, rectangle: rectangle))
    }

    // MARK: - Transforms

    private static func insertionTransform(_ insertion: String) -> MultiCaretApplier.TextTransform {
        let insertedLength = (insertion as NSString).length
        return { text, selection in
            let document = NSMutableString(string: text)
            let range = ColumnEditing.clamped(selection, in: document)
            document.replaceCharacters(in: range, with: insertion)
            return (document as String,
                    NSRange(location: range.location + insertedLength, length: 0))
        }
    }

    private static let deletionTransform: MultiCaretApplier.TextTransform = { text, selection in
        let document = NSMutableString(string: text)
        let range = ColumnEditing.clamped(selection, in: document)
        document.deleteCharacters(in: range)
        return (document as String, NSRange(location: range.location, length: 0))
    }

    private static func clamped(_ selection: NSRange, in text: NSString) -> NSRange {
        guard selection.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(selection.location, text.length))
        let length = max(0, min(selection.length, text.length - location))
        return NSRange(location: location, length: length)
    }
}
