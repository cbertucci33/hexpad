import Foundation

/// The whitespace policy used by the line-indent commands.
///
/// The editor commands are Kit-owned but the active policy lives in the app's
/// `Preferences` (tab size and tabs-vs-spaces). Commands therefore accept the
/// policy as a macro-style parameter string ("spaces:4", "tabs:2"), while the
/// plain ``CommandRegistry`` execution path falls back to ``default``.
public struct IndentSettings: Equatable {

    /// The tab width used when indenting with spaces.
    public let tabSize: Int

    /// Whether one indent level is a real tab instead of `tabSize` spaces.
    public let useTabs: Bool

    public init(tabSize: Int = 4, useTabs: Bool = false) {
        self.tabSize = max(1, tabSize)
        self.useTabs = useTabs
    }

    /// The four-space default used when no preference is supplied.
    public static let `default` = IndentSettings()

    /// One indent level as text.
    public var unit: String {
        useTabs ? "\t" : String(repeating: " ", count: tabSize)
    }

    /// The macro-style parameter form consumed by the registry commands.
    public var parameter: String {
        "\(useTabs ? "tabs" : "spaces"):\(tabSize)"
    }

    /// Parses a ``parameter`` string. Unknown forms return `nil` so callers
    /// can fall back to their own policy.
    public init?(parameter: String) {
        let parts = parameter.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let size = Int(parts[1]),
              size > 0 else {
            return nil
        }
        switch parts[0] {
        case "tabs":
            self.init(tabSize: size, useTabs: true)
        case "spaces":
            self.init(tabSize: size, useTabs: false)
        default:
            return nil
        }
    }
}

/// Notepad++-style line indentation.
///
/// Like the other line operations, these are pure functions over a document
/// and a UTF-16 selection. Every whole line touched by the selection (or the
/// caret's line when the selection is collapsed) is shifted by exactly one
/// indent level, and the returned selection covers the same lines after the
/// transform so the caller can apply everything as one undoable replacement.
public struct IndentOps {

    // MARK: - Indent / dedent

    /// Add one indent level to every selected line.
    ///
    /// The level is a tab or `tabSize` spaces according to `settings`.
    /// Existing indentation is kept, so relative indentation is preserved.
    public static func indentLines(_ text: String,
                                   selection: NSRange,
                                   settings: IndentSettings = .default) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        let span = selectedLineSpan(sel, in: ns)
        let prefix = settings.unit

        let edits = lineSpans(in: span, of: ns).map { line in
            TextEdit(location: line.content.location,
                     deletedLength: 0,
                     insertedText: prefix)
        }
        return applying(edits, to: ns, selection: sel)
    }

    /// Remove up to one indent level from every selected line.
    ///
    /// A leading tab is one level; spaces are removed up to `tabSize`, and a
    /// shorter whitespace-only indent is removed completely. Deeper indentation
    /// is left intact, so relative indentation survives (N++ removes one
    /// level, not all leading whitespace).
    public static func dedentLines(_ text: String,
                                   selection: NSRange,
                                   settings: IndentSettings = .default) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        let span = selectedLineSpan(sel, in: ns)

        let edits = lineSpans(in: span, of: ns).compactMap { line -> TextEdit? in
            let removable = removableIndentLength(in: ns, at: line.content.location, settings: settings)
            guard removable > 0 else { return nil }
            return TextEdit(location: line.content.location,
                            deletedLength: removable,
                            insertedText: "")
        }
        return applying(edits, to: ns, selection: sel)
    }

    // MARK: - Convenience

    /// Add one indent level using explicit preferences.
    public static func indentLines(_ text: String,
                                   selection: NSRange,
                                   tabSize: Int,
                                   useTabs: Bool) -> (text: String, selection: NSRange) {
        indentLines(text, selection: selection,
                    settings: IndentSettings(tabSize: tabSize, useTabs: useTabs))
    }

    /// Remove one indent level using explicit preferences.
    public static func dedentLines(_ text: String,
                                   selection: NSRange,
                                   tabSize: Int,
                                   useTabs: Bool) -> (text: String, selection: NSRange) {
        dedentLines(text, selection: selection,
                    settings: IndentSettings(tabSize: tabSize, useTabs: useTabs))
    }

    // MARK: - Private types

    /// A line's full range (including its terminator) and content range
    /// (excluding its terminator).
    private struct LineSpan {
        let full: NSRange
        let content: NSRange
    }

    /// A single replacement in original document coordinates.
    private struct TextEdit {
        let location: Int
        let deletedLength: Int
        let insertedText: String

        var insertedLength: Int { (insertedText as NSString).length }
    }

    // MARK: - Private helpers

    private static func applying(_ edits: [TextEdit],
                                 to text: NSString,
                                 selection: NSRange) -> (text: String, selection: NSRange) {
        guard !edits.isEmpty else { return (text as String, selection) }

        let mutable = NSMutableString(string: text as String)
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: NSRange(location: edit.location,
                                                  length: edit.deletedLength),
                                      with: edit.insertedText)
        }

        // A caret at a line start moves with that line's new indentation. A
        // non-empty selection keeps covering the same characters, so the
        // inserted indentation is included rather than shifting its start.
        let isCaret = selection.length == 0
        let start = mapOffset(selection.location, through: edits, shiftInsertionsAtOffset: isCaret)
        let end = mapOffset(selection.location + selection.length,
                            through: edits,
                            shiftInsertionsAtOffset: false)
        return (mutable as String,
                NSRange(location: start, length: max(0, end - start)))
    }

    /// Number of UTF-16 units of the line's leading whitespace that make up one
    /// indent level.
    private static func removableIndentLength(in text: NSString,
                                              at location: Int,
                                              settings: IndentSettings) -> Int {
        var length = 0
        while location + length < text.length && length < settings.tabSize {
            let character = text.character(at: location + length)
            if character == 0x0009 {
                // A tab is a whole level. If spaces preceded it, take them too:
                // together they describe the same tab stop.
                return length + 1
            }
            guard character == 0x0020 else { break }
            length += 1
        }
        return length
    }

    private static func clamped(_ selection: NSRange, in text: NSString) -> NSRange {
        guard selection.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(selection.location, text.length))
        let length = max(0, min(selection.length, text.length - location))
        return NSRange(location: location, length: length)
    }

    private static func lineSpan(at location: Int, in text: NSString) -> LineSpan {
        let clampedLocation = max(0, min(location, text.length))
        var start = 0
        var end = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: clampedLocation, length: 0))
        return LineSpan(full: NSRange(location: start, length: end - start),
                        content: NSRange(location: start, length: contentsEnd - start))
    }

    /// Range covering every line touched by `selection`.
    ///
    /// A non-empty selection ending exactly at the start of a line does not
    /// include that following line: the last selected character is the
    /// preceding line terminator.
    private static func selectedLineSpan(_ selection: NSRange, in text: NSString) -> LineSpan {
        let first = lineSpan(at: selection.location, in: text)
        let lastLocation: Int
        if selection.length > 0 {
            lastLocation = selection.location + selection.length - 1
        } else {
            lastLocation = selection.location
        }
        let last = lineSpan(at: lastLocation, in: text)
        return LineSpan(full: NSRange(location: first.full.location,
                                      length: last.full.upperBound - first.full.location),
                        content: NSRange(location: first.full.location,
                                         length: last.content.upperBound - first.full.location))
    }

    private static func lineSpans(in span: LineSpan, of text: NSString) -> [LineSpan] {
        guard span.full.length > 0 else { return [lineSpan(at: span.full.location, in: text)] }
        var spans: [LineSpan] = []
        var location = span.full.location
        while location < span.full.upperBound {
            let current = lineSpan(at: location, in: text)
            spans.append(current)
            guard current.full.upperBound > location else { break }
            location = current.full.upperBound
        }
        return spans
    }

    /// Maps an original UTF-16 offset through edits that only touch line
    /// prefixes. Unless `shiftInsertionsAtOffset` is set (used for carets),
    /// insertions exactly at `offset` are treated as outside the mapped range
    /// so a selection keeps covering the same characters.
    private static func mapOffset(_ offset: Int,
                                  through edits: [TextEdit],
                                  shiftInsertionsAtOffset: Bool) -> Int {
        var delta = 0
        for edit in edits.sorted(by: { $0.location < $1.location }) {
            if edit.deletedLength == 0 {
                if edit.location < offset || (shiftInsertionsAtOffset && edit.location == offset) {
                    delta += edit.insertedLength
                } else {
                    break
                }
            } else if edit.location + edit.deletedLength <= offset {
                delta += edit.insertedLength - edit.deletedLength
            } else if edit.location < offset {
                return edit.location + delta + edit.insertedLength
            } else {
                break
            }
        }
        return offset + delta
    }
}
