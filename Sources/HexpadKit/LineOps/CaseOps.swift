import Foundation

/// Pure text-case conversions behind Notepad++'s Edit > Convert Case to menu.
///
/// Every operation is a pure function over a document and a UTF-16 selection.
/// A non-empty selection is converted in place; an empty selection falls back
/// to the contiguous word at the caret, exactly like Notepad++ (a caret
/// between words therefore converts the word that ends at the caret). When the
/// caret touches no word character at all the document is returned unchanged.
///
/// The returned selection covers the converted text, so the caller can apply
/// the whole operation as a single undoable replacement.
public struct CaseOps {

    // MARK: - Simple case changes

    /// Convert the target to upper case.
    public static func uppercase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ $0.uppercased() }, text: text, selection: selection)
    }

    /// Convert the target to lower case.
    public static func lowercase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ $0.lowercased() }, text: text, selection: selection)
    }

    /// Convert the target to `iNVERT cASE`: every cased character swaps case.
    public static func invertCase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ $0.map { invertedCase(of: $0) }.joined() }, text: text, selection: selection)
    }

    /// Convert the target to `ranDOm CasE`: every cased character is randomly
    /// upper- or lower-cased. Uncased characters (digits, punctuation, spaces)
    /// are left alone.
    ///
    /// The seed is deliberately not configurable; the `roll` overload exists as
    /// a deterministic seam for tests.
    public static func randomCase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        randomCase(text, selection: selection, roll: { Bool.random() })
    }

    /// Deterministic form of ``randomCase(_:selection:)`` used by tests.
    static func randomCase(_ text: String,
                           selection: NSRange,
                           roll: () -> Bool) -> (text: String, selection: NSRange) {
        applying({ randomize($0, roll: roll) }, text: text, selection: selection)
    }

    // MARK: - Proper case

    /// Convert the target to Proper Case: the first letter of each word is
    /// upper-cased and the remaining letters are lower-cased.
    public static func properCase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ properCased($0, blend: false) }, text: text, selection: selection)
    }

    /// Convert the target to Proper Case (blend).
    ///
    /// Like ``properCase(_:selection:)``, except words that are already all
    /// upper case are preserved verbatim, so acronyms survive ("hello NASA"
    /// becomes "Hello NASA"). A mixed-case word is still title-cased.
    public static func properCaseBlend(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ properCased($0, blend: true) }, text: text, selection: selection)
    }

    // MARK: - Sentence case

    /// Convert the target to Sentence case: the first letter of each sentence
    /// is upper-cased and every other letter lower-cased.
    ///
    /// A sentence starts at the beginning of the text, after `.`, `!` or `?`,
    /// and after a line break. Leading quotes, brackets or digits do not cancel
    /// the start of the sentence; the first letter is the one capitalized.
    public static func sentenceCase(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ sentenceCased($0, blend: false) }, text: text, selection: selection)
    }

    /// Convert the target to Sentence case (blend).
    ///
    /// Like ``sentenceCase(_:selection:)``, except all-upper-case words are
    /// preserved verbatim ("hello NASA. next" becomes "Hello NASA. Next").
    public static func sentenceCaseBlend(_ text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        applying({ sentenceCased($0, blend: true) }, text: text, selection: selection)
    }

    // MARK: - Target resolution

    /// Runs `transform` over the selection, or over the word at the caret when
    /// the selection is empty, and maps the selection onto the result.
    private static func applying(_ transform: (String) -> String,
                                 text: String,
                                 selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let caret = clamped(selection, in: ns.length)
        let target: NSRange
        if caret.length > 0 {
            target = caret
        } else if let word = wordRange(at: caret.location, in: text) {
            target = word
        } else {
            return (text, caret)
        }

        let replacement = transform(ns.substring(with: target))
        let newText = ns.replacingCharacters(in: target, with: replacement)
        return (newText, NSRange(location: target.location,
                                 length: (replacement as NSString).length))
    }

    /// The contiguous run of word characters containing `caret`.
    ///
    /// Scans backwards from the caret and forwards from it, so a caret at the
    /// end of a word still selects that word. A caret surrounded by non-word
    /// characters yields `nil`.
    private static func wordRange(at caret: Int, in text: String) -> NSRange? {
        let length = text.utf16.count
        let location = max(0, min(caret, length))
        var start = String.Index(utf16Offset: location, in: text)
        var end = start

        while start > text.startIndex {
            let previous = text.index(before: start)
            guard isWordCharacter(text[previous]) else { break }
            start = previous
        }
        while end < text.endIndex {
            guard isWordCharacter(text[end]) else { break }
            end = text.index(after: end)
        }

        guard start < end else { return nil }
        let startOffset = start.utf16Offset(in: text)
        let endOffset = end.utf16Offset(in: text)
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func clamped(_ selection: NSRange, in length: Int) -> NSRange {
        guard selection.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let location = max(0, min(selection.location, length))
        let requestedLength = max(0, selection.length)
        return NSRange(location: location, length: min(requestedLength, length - location))
    }

    // MARK: - Transforms

    /// Splits `text` into letter runs and non-letters, title-casing each run.
    private static func properCased(_ text: String, blend: Bool) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter else {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            var end = text.index(after: index)
            while end < text.endIndex, text[end].isLetter {
                end = text.index(after: end)
            }
            result += titleCased(String(text[index..<end]), blend: blend)
            index = end
        }
        return result
    }

    /// Sentence-cases letter runs while carrying the sentence-start flag across
    /// punctuation and whitespace.
    private static func sentenceCased(_ text: String, blend: Bool) -> String {
        var result = ""
        var startsSentence = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter else {
                result.append(character)
                if isSentenceTerminator(character) {
                    startsSentence = true
                }
                index = text.index(after: index)
                continue
            }

            var end = text.index(after: index)
            while end < text.endIndex, text[end].isLetter {
                end = text.index(after: end)
            }
            let word = String(text[index..<end])
            if blend, isAllUppercase(word) {
                result += word
            } else if startsSentence {
                result += titleCased(word, blend: false)
            } else {
                result += word.lowercased()
            }
            startsSentence = false
            index = end
        }
        return result
    }

    private static func titleCased(_ word: String, blend: Bool) -> String {
        if blend, isAllUppercase(word) { return word }
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst().lowercased()
    }

    /// Whether every letter in `word` is already upper case. The callers only
    /// pass letter runs, but non-letters are ignored defensively.
    private static func isAllUppercase(_ word: String) -> Bool {
        word.contains(where: { $0.isLetter })
            && word.allSatisfy { !$0.isLetter || String($0) == String($0).uppercased() }
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character.isNewline
    }

    private static func invertedCase(of character: Character) -> String {
        let original = String(character)
        let lower = original.lowercased()
        let upper = original.uppercased()
        guard lower != upper else { return original }
        return original == upper ? lower : upper
    }

    private static func randomize(_ text: String, roll: () -> Bool) -> String {
        var result = ""
        for character in text {
            let original = String(character)
            let lower = original.lowercased()
            let upper = original.uppercased()
            guard lower != upper else {
                result += original
                continue
            }
            result += roll() ? upper : lower
        }
        return result
    }
}
