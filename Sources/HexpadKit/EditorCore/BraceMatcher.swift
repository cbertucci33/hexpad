import Foundation

/// Nesting-aware matching of the bracket pairs declared by a `LexerDefinition`.
///
/// This is pure logic: it reads a document string, a UTF-16 caret offset and
/// the language's bracket pairs, and never touches AppKit. The anchor is the
/// bracket immediately before the caret (preferred) or immediately after it.
/// Nesting is tracked per pair: another open of the *same* pair inside the
/// region increments depth, while other declared pairs are ignored. Multi-char
/// opens/closes are matched by string comparison rather than single characters.
///
/// Known limitation (acceptable for this slice): this is a plain scan and does
/// not skip brackets that appear inside strings or comments.
public struct BraceMatcher {

    /// Both ends of a successful match, in document order.
    public struct Match {
        /// Range of the bracket adjacent to the caret.
        public let caretBracket: NSRange
        /// Range of the bracket paired with `caretBracket`.
        public let matchedBracket: NSRange
        /// Range of the opening bracket.
        public let openBracket: NSRange
        /// Range of the closing bracket.
        public let closeBracket: NSRange
        /// Whether the caret-adjacent bracket is the opener.
        public let caretIsOpen: Bool

        /// The text strictly between the two brackets, exclusive of both.
        public var innerRange: NSRange {
            let start = openBracket.location + openBracket.length
            return NSRange(location: start,
                           length: max(0, closeBracket.location - start))
        }
    }

    /// A token belonging to a declared bracket pair, together with its range in
    /// the document. Used for both the caret-adjacent anchor and the scan.
    private struct Token {
        let pair: LexerDefinition.BracketPair
        let text: String
        let isOpen: Bool
        let range: NSRange
    }

    /// Range of the declared bracket token touching `caret` (the token ending
    /// at the caret wins, then the one starting there), or `nil` when the caret
    /// is not adjacent to any bracket.
    ///
    /// This is the cheap adjacency pre-check for callers that react to every
    /// caret move: it compares at most one short token per declared pair and
    /// never scans the document. A `nil` result means there is nothing to
    /// match, so the caller can skip ``matchDetail(text:caret:brackets:)``.
    public static func adjacentBracketRange(text: String,
                                           caret: Int,
                                           brackets: [LexerDefinition.BracketPair]) -> NSRange? {
        let document = text as NSString
        guard !brackets.isEmpty, caret >= 0, caret <= document.length else { return nil }
        return (tokenEnding(at: caret, in: document, brackets: brackets)
                ?? tokenStarting(at: caret, in: document, brackets: brackets))?.range
    }

    /// Returns the range of the bracket matched with the bracket adjacent to
    /// `caret`, or `nil` if the caret is not adjacent to a bracket or that
    /// bracket is unmatched.
    public static func match(text: String,
                             caret: Int,
                             brackets: [LexerDefinition.BracketPair]) -> NSRange? {
        matchDetail(text: text, caret: caret, brackets: brackets)?.matchedBracket
    }

    /// Returns the full match (both bracket ranges plus the in-between range),
    /// or `nil` when there is no match. Callers that need the text between the
    /// brackets use this rather than ``match(text:caret:brackets:)``.
    public static func matchDetail(text: String,
                                   caret: Int,
                                   brackets: [LexerDefinition.BracketPair]) -> Match? {
        let document = text as NSString
        let length = document.length
        guard !brackets.isEmpty, caret >= 0, caret <= length else { return nil }

        // The bracket immediately before the caret wins; only then do we look
        // at the bracket starting at the caret. Longest token wins at a tie so
        // multi-char pair definitions are handled predictably.
        guard let anchor = tokenEnding(at: caret, in: document, brackets: brackets)
                ?? tokenStarting(at: caret, in: document, brackets: brackets) else {
            return nil
        }

        let open = anchor.pair.open
        let close = anchor.pair.close
        guard (open as NSString).length > 0, (close as NSString).length > 0 else { return nil }

        // Every occurrence of this pair's opener and closer, in document order.
        // The scan is restricted to the anchor's pair, so nested () inside {}
        // never disturb the {} depth count.
        var occurrences: [Token] = []
        for (tokenText, isOpen) in [(open, true), (close, false)] {
            let tokenLength = (tokenText as NSString).length
            var searchLocation = 0
            while searchLocation + tokenLength <= length {
                let found = document.range(
                    of: tokenText,
                    range: NSRange(location: searchLocation,
                                   length: length - searchLocation)
                )
                guard found.location != NSNotFound else { break }
                occurrences.append(Token(pair: anchor.pair,
                                         text: tokenText,
                                         isOpen: isOpen,
                                         range: found))
                searchLocation = found.location + tokenLength
            }
        }
        occurrences.sort { $0.range.location < $1.range.location }

        let anchorEnd = anchor.range.location + anchor.range.length
        if anchor.isOpen {
            // Scan forward: another opener deepens, a closer shallows. The
            // closer that returns depth to zero is the match.
            var depth = 1
            for token in occurrences where token.range.location >= anchorEnd {
                if token.isOpen {
                    depth += 1
                } else {
                    depth -= 1
                    if depth == 0 {
                        return Match(caretBracket: anchor.range,
                                     matchedBracket: token.range,
                                     openBracket: anchor.range,
                                     closeBracket: token.range,
                                     caretIsOpen: true)
                    }
                }
            }
        } else {
            // Scan backward: a closer deepens, an opener shallows. The opener
            // that returns depth to zero is the match.
            var depth = 1
            for token in occurrences.reversed()
                where token.range.location + token.range.length <= anchor.range.location {
                if token.isOpen {
                    depth -= 1
                    if depth == 0 {
                        return Match(caretBracket: anchor.range,
                                     matchedBracket: token.range,
                                     openBracket: token.range,
                                     closeBracket: anchor.range,
                                     caretIsOpen: false)
                    }
                } else {
                    depth += 1
                }
            }
        }
        return nil
    }

    /// A declared opener or closer whose range ends exactly at `end`.
    private static func tokenEnding(at end: Int,
                                    in document: NSString,
                                    brackets: [LexerDefinition.BracketPair]) -> Token? {
        guard end > 0 else { return nil }
        var best: Token?
        for pair in brackets {
            for (text, isOpen) in [(pair.open, true), (pair.close, false)] {
                let tokenLength = (text as NSString).length
                guard tokenLength > 0, tokenLength <= end else { continue }
                let range = NSRange(location: end - tokenLength, length: tokenLength)
                guard document.substring(with: range) == text else { continue }
                if best == nil || tokenLength > best!.range.length {
                    best = Token(pair: pair, text: text, isOpen: isOpen, range: range)
                }
            }
        }
        return best
    }

    /// A declared opener or closer whose range starts exactly at `start`.
    private static func tokenStarting(at start: Int,
                                      in document: NSString,
                                      brackets: [LexerDefinition.BracketPair]) -> Token? {
        guard start < document.length else { return nil }
        var best: Token?
        for pair in brackets {
            for (text, isOpen) in [(pair.open, true), (pair.close, false)] {
                let tokenLength = (text as NSString).length
                guard tokenLength > 0, start + tokenLength <= document.length else { continue }
                let range = NSRange(location: start, length: tokenLength)
                guard document.substring(with: range) == text else { continue }
                if best == nil || tokenLength > best!.range.length {
                    best = Token(pair: pair, text: text, isOpen: isOpen, range: range)
                }
            }
        }
        return best
    }
}
