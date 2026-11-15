import Foundation
import HexpadKit

/// Pure text transforms and diffing used by the editor's multi-caret wiring.
///
/// The Kit-side ``MultiCaretApplier`` owns the caret-aware application order;
/// this type only supplies the individual `(text, selection) -> (text, selection)`
/// transforms for typing and deletion, plus the minimal replacement used to
/// apply the final document as one undoable edit.
enum MultiCaretEditing {

    /// One contiguous replacement that turns one string into another.
    struct TextChange: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// Inserts `insertion` at a selection, replacing it when it has a length.
    ///
    /// This mirrors typing over a selection: the returned caret sits directly
    /// after the inserted text.
    static func insertionTransform(_ insertion: String) -> MultiCaretApplier.TextTransform {
        let insertedLength = (insertion as NSString).length
        return { text, selection in
            let document = NSMutableString(string: text)
            let range = clamped(selection, in: document)
            document.replaceCharacters(in: range, with: insertion)
            return (document as String,
                    NSRange(location: range.location + insertedLength, length: 0))
        }
    }

    /// Deletes the selection, or one composed character in the requested
    /// direction when the caret is a zero-length insertion point.
    ///
    /// Composed-character ranges keep backspace from splitting a surrogate
    /// pair (an emoji disappears in one keystroke, matching AppKit).
    static func deletionTransform(forward: Bool = false) -> MultiCaretApplier.TextTransform {
        { text, selection in
            let document = NSMutableString(string: text)
            let range = clamped(selection, in: document)

            if range.length > 0 {
                document.deleteCharacters(in: range)
                return (document as String, NSRange(location: range.location, length: 0))
            }

            if forward {
                guard range.location < document.length else {
                    return (text, range)
                }
                let deleting = document.rangeOfComposedCharacterSequence(at: range.location)
                document.deleteCharacters(in: deleting)
                return (document as String, NSRange(location: range.location, length: 0))
            }

            guard range.location > 0 else {
                return (text, range)
            }
            let deleting = document.rangeOfComposedCharacterSequence(at: range.location - 1)
            document.deleteCharacters(in: deleting)
            return (document as String, NSRange(location: deleting.location, length: 0))
        }
    }

    /// The smallest contiguous replacement that turns `oldText` into `newText`.
    ///
    /// `DocumentModel.replaceCharacters` registers one undo action per call, so
    /// applying a multi-caret result through this diff keeps the whole action
    /// (typing, backspace, or paste at every caret) as a single undo step while
    /// avoiding a whole-buffer replacement for ordinary single-line edits.
    ///
    /// Returns `nil` when the strings are equal.
    static func change(from oldText: String, to newText: String) -> TextChange? {
        guard oldText != newText else { return nil }

        let old = oldText as NSString
        let new = newText as NSString
        let sharedLength = min(old.length, new.length)

        var prefix = 0
        while prefix < sharedLength,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        while suffix < sharedLength - prefix,
              old.character(at: old.length - 1 - suffix)
                == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }

        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix,
                                                       length: new.length - prefix - suffix))
        return TextChange(range: range, replacement: replacement)
    }

    // MARK: - Helpers

    /// Clamps a selection so a malformed range can never trap a text mutation.
    private static func clamped(_ selection: NSRange, in text: NSString) -> NSRange {
        guard selection.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        let location = max(0, min(selection.location, text.length))
        let length = max(0, min(selection.length, text.length - location))
        return NSRange(location: location, length: length)
    }
}
