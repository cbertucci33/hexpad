import Foundation

/// One search hit inside a single document buffer, ready to be shown in the
/// results window: the match itself, where it sits (1-based line and UTF-16
/// column) and the full logical line it lives on.
public struct DocumentMatch: Equatable {
    /// Absolute UTF-16 range into the searched buffer.
    public let range: NSRange
    /// The matched text exactly as it appears in the buffer.
    public let text: String
    /// 1-based logical line number, using the same LF-only convention as
    /// ``LineIndex`` and ``GutterGeometry``.
    public let line: Int
    /// 1-based column in UTF-16 code units from the start of the line. This is
    /// the same coordinate space as ``NSRange`` (an emoji counts as two).
    public let column: Int
    /// The logical line containing the match, without its line ending. Used as
    /// the result row's context preview.
    public let context: String

    public init(range: NSRange, text: String, line: Int, column: Int, context: String) {
        self.range = range
        self.text = text
        self.line = line
        self.column = column
        self.context = context
    }
}

public extension SearchEngine {

    /// Find every match in one document and annotate it with line/column and
    /// the surrounding line.
    ///
    /// This reuses ``SearchEngine/search(_:pattern:options:range:)`` for the
    /// actual matching, so literal/regex/whole-word/case behaviour is exactly
    /// the same as Find Next and Find in Files. Building the line index costs
    /// one O(document) pass; each match then costs O(log lines) for its line
    /// lookup plus O(line length) to slice the context, i.e. O(document +
    /// matches × log lines) overall. That is deliberately simple: the action is
    /// user-triggered, not a typing-path operation.
    ///
    /// `range` limits the search like it does for `search`; nil means the whole
    /// buffer. Returned ranges stay absolute offsets into `text`.
    static func findAll(in text: String, pattern: String, options: SearchOptions,
                        range: NSRange? = nil) -> [DocumentMatch] {
        let matches = search(text, pattern: pattern, options: options, range: range)
        guard !matches.isEmpty else { return [] }

        let nsText = text as NSString
        let lineIndex = LineIndex(text)

        return matches.map { match in
            let line = lineIndex.line(of: match.range.location)
            let lineStart = lineIndex.firstCharIndex(of: line)
            let nextLineStart = line < lineIndex.count
                ? lineIndex.firstCharIndex(of: line + 1)
                : lineIndex.textLength
            var context = nsText.substring(with: NSRange(location: lineStart,
                                                         length: max(0, nextLineStart - lineStart)))
            // Buffers are LF-only by construction, but stripping CR too keeps
            // the preview clean for text that arrived with CRLF line endings.
            // Compare Unicode scalars, not Characters: "\r\n" is one grapheme,
            // so hasSuffix("\n")/("\r") would never match it.
            while let last = context.unicodeScalars.last, last == "\n" || last == "\r" {
                context.unicodeScalars.removeLast()
            }
            return DocumentMatch(range: match.range,
                                 text: match.text,
                                 line: line,
                                 column: match.range.location - lineStart + 1,
                                 context: context)
        }
    }
}
