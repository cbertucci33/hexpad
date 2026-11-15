import Foundation

/// Operations on line-oriented text
public struct LineOps {
    
    /// Sort lines alphabetically (ascending)
    public static func sortAscending(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: "\n")
    }
    
    /// Sort lines alphabetically (descending)
    public static func sortDescending(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.sorted { $0.lowercased() > $1.lowercased() }.joined(separator: "\n")
    }
    
    /// Remove duplicate lines (keeping first occurrence)
    public static func removeDuplicates(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            if !seen.contains(line) {
                seen.insert(line)
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }
    
    /// Remove blank lines
    public static func removeBlankLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
    
    /// Join all lines into a single line
    public static func joinLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.joined(separator: " ")
    }
    
    /// Split lines by a delimiter
    public static func splitLines(_ text: String, delimiter: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.replacingOccurrences(of: delimiter, with: "\n") }.joined(separator: "\n")
    }
    
    /// Reverse the order of lines
    public static func reverseLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.reversed().joined(separator: "\n")
    }
    
    /// Trim leading whitespace from all lines
    public static func trimLeading(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
    
    /// Trim trailing whitespace from all lines
    public static func trimTrailing(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
    
    /// Trim whitespace from both sides of all lines
    public static func trimAll(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }
    
    /// Indent selected lines
    public static func indent(_ text: String, by amount: Int) -> String {
        let prefix = String(repeating: " ", count: amount)
        let lines = text.components(separatedBy: "\n")
        return lines.map { prefix + $0 }.joined(separator: "\n")
    }
    
    /// Dedent selected lines
    public static func dedent(_ text: String, by amount: Int) -> String {
        let prefix = String(repeating: " ", count: amount)
        let lines = text.components(separatedBy: "\n")
        return lines.map { $0.hasPrefix(prefix) ? String($0.dropFirst(amount)) : $0 }.joined(separator: "\n")
    }

    // MARK: - Selection-aware operations

    // These operations are pure functions over a document and a UTF-16
    // selection. They return the mutated document together with the selection
    // that should be restored after the caller applies the text as a single
    // undoable replacement.

    /// Duplicate the lines touched by `selection`.
    ///
    /// The duplicate is inserted directly below the selected block and the
    /// returned selection covers the duplicate, so repeating the command keeps
    /// duplicating the same block.
    public static func duplicateLine(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        let span = selectedLineSpan(sel, in: ns)
        let block = ns.substring(with: span.full)
        let endsWithTerminator = hasLineTerminator(atEndOf: span.full, in: ns)
        let separator = endsWithTerminator ? "" : preferredLineEnding(in: ns)
        let insertion = separator + block
        let insertionLocation = span.full.upperBound
        let newText = ns.replacingCharacters(in: NSRange(location: insertionLocation, length: 0), with: insertion)
        let selectionLocation = insertionLocation
            + (separator as NSString).length
            + (sel.location - span.full.location)
        return (newText, NSRange(location: selectionLocation, length: sel.length))
    }

    /// Delete the lines touched by `selection`.
    ///
    /// When the final line has no terminator, the preceding line ending is
    /// removed as well so no dangling blank line is left behind. The returned
    /// selection is a caret at the deletion point.
    public static func deleteLine(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        let span = selectedLineSpan(sel, in: ns)

        var deletion = span.full
        if !hasLineTerminator(atEndOf: span.full, in: ns) && span.full.location > 0 {
            let preceding = lineEndingLength(before: span.full.location, in: ns)
            deletion = NSRange(location: span.full.location - preceding,
                               length: span.full.length + preceding)
        }
        let newText = ns.replacingCharacters(in: deletion, with: "")
        return (newText, NSRange(location: deletion.location, length: 0))
    }

    /// Move the lines touched by `selection` one line up.
    ///
    /// The selection follows the moved block. Moving the first line is a no-op.
    public static func moveLineUp(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        let span = selectedLineSpan(sel, in: ns)
        guard span.full.location > 0 else { return (text, sel) }

        let previous = lineSpan(at: span.full.location - 1, in: ns)
        let previousContent = ns.substring(with: NSRange(location: previous.content.location,
                                                         length: previous.content.length))
        let previousTerminator = ns.substring(with: NSRange(location: previous.content.upperBound,
                                                            length: span.full.location - previous.content.upperBound))
        let blockContent = ns.substring(with: span.content)
        let blockTerminator = ns.substring(with: NSRange(location: span.content.upperBound,
                                                         length: span.full.upperBound - span.content.upperBound))

        let replacement = blockContent + previousTerminator + previousContent + blockTerminator
        let replacedRange = NSRange(location: previous.full.location,
                                    length: span.full.upperBound - previous.full.location)
        let newText = ns.replacingCharacters(in: replacedRange, with: replacement)
        let selectionLocation = previous.full.location + (sel.location - span.full.location)
        return (newText, NSRange(location: selectionLocation, length: sel.length))
    }

    /// Move the lines touched by `selection` one line down.
    ///
    /// The selection follows the moved block. Moving the last line (a block
    /// that reaches the end of the document) is a no-op.
    public static func moveLineDown(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        let span = selectedLineSpan(sel, in: ns)
        guard span.full.upperBound < ns.length else { return (text, sel) }

        let next = lineSpan(at: span.full.upperBound, in: ns)
        let blockContent = ns.substring(with: span.content)
        let blockTerminator = ns.substring(with: NSRange(location: span.content.upperBound,
                                                         length: span.full.upperBound - span.content.upperBound))
        let nextContent = ns.substring(with: next.content)
        let nextTerminator = ns.substring(with: NSRange(location: next.content.upperBound,
                                                        length: next.full.upperBound - next.content.upperBound))

        let replacement = nextContent + blockTerminator + blockContent + nextTerminator
        let replacedRange = NSRange(location: span.full.location,
                                    length: next.full.upperBound - span.full.location)
        let newText = ns.replacingCharacters(in: replacedRange, with: replacement)
        let selectionLocation = span.full.location
            + (nextContent as NSString).length
            + (blockTerminator as NSString).length
            + (sel.location - span.full.location)
        return (newText, NSRange(location: selectionLocation, length: sel.length))
    }

    /// Toggle a line-comment prefix on the lines touched by `selection`.
    ///
    /// If every non-blank line is already commented the prefix is removed;
    /// otherwise the prefix is added after each line's indentation. Blank lines
    /// are left untouched.
    public static func toggleLineComment(_ text: String,
                                         selection: NSRange,
                                         prefix: String = "//") -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        guard !prefix.isEmpty else { return (text, sel) }

        let span = selectedLineSpan(sel, in: ns)
        let lines = lineSpans(in: span, of: ns)
        let prefixLength = (prefix as NSString).length

        struct LineInfo {
            let span: LineSpan
            let indentation: Int
            let isBlank: Bool
            let isCommented: Bool
        }

        let infos: [LineInfo] = lines.map { line in
            let content = ns.substring(with: line.content)
            let indentation = leadingWhitespaceLength(in: content)
            let rest = (content as NSString).substring(from: indentation)
            let isBlank = content.trimmingCharacters(in: .whitespaces).isEmpty
            return LineInfo(span: line,
                            indentation: indentation,
                            isBlank: isBlank,
                            isCommented: rest.hasPrefix(prefix))
        }

        let nonBlank = infos.filter { !$0.isBlank }
        guard !nonBlank.isEmpty else { return (text, sel) }

        let shouldRemove = nonBlank.allSatisfy { $0.isCommented }
        let edits: [TextEdit] = nonBlank.map { info in
            let location = info.span.content.location + info.indentation
            if shouldRemove {
                return TextEdit(location: location, deletedLength: prefixLength, insertedText: "")
            } else {
                return TextEdit(location: location, deletedLength: 0, insertedText: prefix)
            }
        }

        let mutable = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            mutable.replaceCharacters(in: NSRange(location: edit.location, length: edit.deletedLength),
                                      with: edit.insertedText)
        }

        // A caret is an insertion point, so an insertion exactly at it moves
        // it along with the inserted prefix. A non-empty selection keeps
        // covering the same characters, so its boundaries stay put.
        let isCaret = sel.length == 0
        let start = mapOffset(sel.location, through: edits, shiftInsertionsAtOffset: isCaret)
        let end = mapOffset(sel.location + sel.length, through: edits, shiftInsertionsAtOffset: false)
        return (mutable as String, NSRange(location: start, length: max(0, end - start)))
    }

    /// Uppercase the selected text. An empty selection is a no-op.
    public static func uppercase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        transformCase(text, selection: selection, transform: { $0.uppercased() })
    }

    /// Lowercase the selected text. An empty selection is a no-op.
    public static func lowercase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        transformCase(text, selection: selection, transform: { $0.lowercased() })
    }

    // MARK: - Private helpers

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

    private static func transformCase(_ text: String,
                                      selection: NSRange,
                                      transform: (String) -> String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        guard sel.length > 0 else { return (text, sel) }
        let selected = ns.substring(with: sel)
        let transformed = transform(selected)
        let newText = ns.replacingCharacters(in: sel, with: transformed)
        return (newText, NSRange(location: sel.location, length: (transformed as NSString).length))
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

    private static func isLineTerminator(_ character: unichar) -> Bool {
        character == 0x000A || character == 0x000D || character == 0x0085
            || character == 0x2028 || character == 0x2029
    }

    private static func hasLineTerminator(atEndOf range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0 else { return false }
        return isLineTerminator(text.character(at: range.upperBound - 1))
    }

    /// Length of the line ending immediately before `location` (0 when the
    /// preceding character is not a line terminator).
    private static func lineEndingLength(before location: Int, in text: NSString) -> Int {
        guard location > 0, location <= text.length else { return 0 }
        let previous = text.character(at: location - 1)
        guard isLineTerminator(previous) else { return 0 }
        if previous == 0x000A, location >= 2, text.character(at: location - 2) == 0x000D {
            return 2
        }
        return 1
    }

    private static func preferredLineEnding(in text: NSString) -> String {
        let string = text as String
        if string.contains("\r\n") { return "\r\n" }
        if string.contains("\r") { return "\r" }
        if string.contains("\n") { return "\n" }
        if string.contains("\u{2028}") { return "\u{2028}" }
        if string.contains("\u{2029}") { return "\u{2029}" }
        return "\n"
    }

    private static func leadingWhitespaceLength(in line: String) -> Int {
        let ns = line as NSString
        var length = 0
        while length < ns.length {
            let character = ns.character(at: length)
            guard character == 0x0020 || character == 0x0009 else { break }
            length += 1
        }
        return length
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
