import Foundation

/// Direction for the Select and Find / Find (Volatile) commands.
public enum SearchDirection {
    case next
    case previous
}

/// Selection-scoped find helpers shared by the four Notepad++ Search menu
/// commands:
///
/// - Select and Find Next / Previous seed the find state from the selection
///   (or word at the caret) and jump to the neighbouring match.
/// - Find (Volatile) Next / Previous make the same jump without keeping the
///   query, so they need only the range resolution and index pick.
///
/// Keeping the range math here means the AppKit layer never re-implements
/// UTF-16 boundary handling, and the "skip the occurrence you are standing on"
/// rule is testable without a window.
public extension SearchEngine {

    /// The range these commands search for: the selection when it has length,
    /// otherwise the word containing the caret.
    ///
    /// Returns nil when the selection is empty and the caret sits on no word,
    /// which is the documented no-op case (the menu item stays enabled).
    static func selectionSearchRange(text: String, selection: NSRange) -> NSRange? {
        let length = (text as NSString).length
        let clamped = clampedSelection(selection, length: length)
        if clamped.length > 0 {
            return clamped
        }
        return wordRange(at: clamped.location, in: text)
    }

    /// The contiguous run of word characters containing `caret`.
    ///
    /// A caret at either edge of a word still belongs to that word: `foo|`
    /// resolves to `foo`, and so does `|foo`. A caret surrounded by
    /// non-word characters (or an empty buffer) yields nil.
    ///
    /// Word characters are alphanumerics plus `_`, matching the `\b` tests the
    /// engine applies for Whole Word. Ranges are UTF-16 offsets like every
    /// other search range.
    static func wordRange(at caret: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return nil }
        let location = min(max(0, caret), length)

        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < length,
                  let scalar = UnicodeScalar(nsText.character(at: index)) else {
                return false
            }
            return wordCharacters.contains(scalar)
        }

        var seed = location
        if !isWord(seed) {
            // Caret directly after a word (`foo|`) belongs to that word.
            guard seed > 0, isWord(seed - 1) else { return nil }
            seed -= 1
        }

        var start = seed
        while start > 0, isWord(start - 1) { start -= 1 }
        var end = seed
        while end < length, isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Index of the match the command should jump to.
    ///
    /// `anchor` is the range the command was invoked from (the selection or
    /// the word at the caret). The anchor's own occurrence is skipped: next
    /// starts at or after the anchor's end, previous ends before its start.
    /// Without a candidate the index wraps to the first/last match when
    /// `wrap` is true, otherwise nil (no-op).
    ///
    /// `matches` must be in ascending location order, which `search` always
    /// produces.
    static func targetMatchIndex(in matches: [SearchMatch], from anchor: NSRange,
                                 direction: SearchDirection, wrap: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        switch direction {
        case .next:
            let anchorEnd = NSMaxRange(anchor)
            if let index = matches.firstIndex(where: { $0.range.location >= anchorEnd }) {
                return index
            }
            return wrap ? 0 : nil
        case .previous:
            if let index = matches.lastIndex(where: { $0.range.location < anchor.location }) {
                return index
            }
            return wrap ? matches.count - 1 : nil
        }
    }

    private static var wordCharacters: CharacterSet {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    }

    private static func clampedSelection(_ selection: NSRange, length: Int) -> NSRange {
        let location = selection.location == NSNotFound
            ? 0
            : min(max(0, selection.location), length)
        let requested = selection.location == NSNotFound ? 0 : max(0, selection.length)
        return NSRange(location: location, length: min(requested, length - location))
    }
}
