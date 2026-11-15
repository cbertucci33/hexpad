import Foundation

/// Applies a line-oriented text transform independently at every caret.
///
/// Transforms use the same shape as the pure `LineOps` functions:
/// `(text, selection) -> (text, selection)`. The applier runs them from the
/// bottom-most caret to the top-most caret so that edits in the lower part of
/// the document do not invalidate the offsets of carets above them. After each
/// edit, every remaining caret is remapped through the change (its offset
/// shifts by the edit delta when the edit lies before it).
///
/// A single-caret state is applied directly, so its result is exactly the same
/// as calling the transform by hand.
public enum MultiCaretApplier {

    /// A pure line-oriented transform over a document and UTF-16 selection.
    public typealias TextTransform = (_ text: String, _ selection: NSRange) -> (text: String, selection: NSRange)

    /// Applies `transform` at every caret in `state`.
    ///
    /// Application order is bottom-most (largest offset) first. The returned
    /// state contains the transformed selections, remapped into the final
    /// document and re-normalized so overlaps cannot survive an edit.
    public static func apply(_ transform: TextTransform,
                             to text: String,
                             state: MultiCaretState) -> (text: String, state: MultiCaretState) {
        let carets = state.carets
        guard !carets.isEmpty else { return (text, state) }

        // With one caret there is nothing to remap: behave exactly like a
        // direct call to the transform.
        if carets.count == 1 {
            let result = transform(text, carets[0])
            return (result.text,
                    MultiCaretState(carets: [result.selection]))
        }

        // Bottom-most first. Carets outside the edited region are remapped by
        // the delta of every edit that precedes them.
        let order = carets.indices.sorted { carets[$0].location > carets[$1].location }

        var working = carets
        var document = text as NSString

        for index in order {
            let oldText = document as String
            let result = transform(oldText, working[index])
            let newText = result.text

            if newText == oldText {
                working[index] = result.selection
                continue
            }

            let newDocument = newText as NSString
            let change = textChange(from: document, to: newDocument)
            document = newDocument

            // The transform already reports the new location of the caret it
            // ran for; all other carets are carried across the edit.
            working[index] = result.selection
            for other in working.indices where other != index {
                working[other] = remap(working[other], through: change)
            }
        }

        return (document as String, MultiCaretState(carets: working))
    }

    /// Convenience overload that works directly with caret ranges.
    public static func apply(_ transform: TextTransform,
                             to text: String,
                             carets: [NSRange]) -> (text: String, carets: [NSRange]) {
        let result = apply(transform, to: text, state: MultiCaretState(carets: carets))
        return (result.text, result.state.carets)
    }

    // MARK: - Private helpers

    /// The single contiguous replacement that turns one text into another.
    private struct TextChange {
        /// Replaced range in the old document.
        let oldRange: NSRange
        /// Length of the replacement in the new document.
        let newLength: Int

        /// Length difference between the new and old document.
        var delta: Int { newLength - oldRange.length }
    }

    /// Finds the changed region by stripping the common prefix and suffix.
    private static func textChange(from old: NSString, to new: NSString) -> TextChange {
        let oldLength = old.length
        let newLength = new.length
        let sharedLength = min(oldLength, newLength)

        var prefix = 0
        while prefix < sharedLength,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        while suffix < sharedLength - prefix,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) {
            suffix += 1
        }

        return TextChange(oldRange: NSRange(location: prefix, length: oldLength - prefix - suffix),
                          newLength: newLength - prefix - suffix)
    }

    /// Maps a caret from the old document through `change` into the new one.
    private static func remap(_ caret: NSRange, through change: TextChange) -> NSRange {
        let start = mapOffset(caret.location, through: change)
        let end = mapOffset(caret.upperBound, through: change)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Maps one UTF-16 offset through `change`.
    private static func mapOffset(_ offset: Int, through change: TextChange) -> Int {
        let editStart = change.oldRange.location
        let editEnd = change.oldRange.upperBound

        if offset < editStart { return offset }
        if offset > editEnd { return offset + change.delta }

        if change.oldRange.length == 0 {
            // Pure insertion: offsets at the insertion point move to the end
            // of the inserted text, matching caret affinity.
            return offset + change.delta
        }
        if offset == editEnd {
            return editStart + change.newLength
        }

        // Inside a replaced/deleted range: clamp to the replacement.
        return editStart + min(offset - editStart, change.newLength)
    }
}
