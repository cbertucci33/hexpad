import Foundation

/// One entry in a document outline.
///
/// `range` is the UTF-16 range of the symbol's name (not of the whole
/// declaration), so a caller can select or scroll to the identifier directly.
/// `line` is the 1-based logical line that contains the name, computed with the
/// same line math the gutter uses.
public struct FunctionSymbol: Hashable {

    /// The symbol's display name, with declaration punctuation removed.
    public let name: String

    /// What kind of construct the symbol names.
    public let kind: SymbolKind

    /// 1-based logical line containing the symbol.
    public let line: Int

    /// UTF-16 range of the symbol's name in the document.
    public let range: NSRange

    /// Alias for `line`, matching the "line number" wording used by editors.
    public var lineNumber: Int { line }

    /// Alias for `range`, making the UTF-16 unit explicit at call sites.
    public var utf16Range: NSRange { range }

    public init(name: String, kind: SymbolKind, line: Int, range: NSRange) {
        self.name = name
        self.kind = kind
        self.line = line
        self.range = range
    }
}

/// A pure, Kit-side outline of the symbols in one document.
///
/// The model does not parse a language independently. Instead it runs the
/// regexes a `LexerDefinition` already declares and interprets the rules the
/// definition lists in its `symbols` metadata. That keeps the outline and the
/// highlighting notion of a function, heading, selector, or tag in lockstep.
///
/// False positives are handled pragmatically:
///
/// - Matches whose names fall inside a comment or string span are skipped.
/// - Matches whose names are covered by the language's keyword, type, or number
///   rules are skipped (`if (` is not a function).
/// - Duplicate symbols on one line are collapsed; callable kinds are limited to
///   one entry per line so a declaration's body on the same line cannot add
///   extra entries.
///
/// The result is sorted by document position. The model has no `NSTextView`
/// dependency; the app can build it from text and hand its entries to a panel.
public struct FunctionListModel {

    /// The document text the outline was computed from.
    public let text: String

    /// The grammar whose rules and `symbols` metadata drive the outline.
    public let definition: LexerDefinition

    /// Outline entries sorted by document position.
    public let symbols: [FunctionSymbol]

    /// Builds an outline using an explicit lexer definition.
    public init(text: String, definition: LexerDefinition) {
        self.text = text
        self.definition = definition
        self.symbols = FunctionListModel.extractSymbols(from: text, definition: definition)
    }

    /// Builds an outline for a language through the definition registry.
    ///
    /// `Language.plain` (and any language without a grammar) has no symbol
    /// metadata, so the resulting outline is empty.
    public init(text: String, language: Language) {
        let definition = LexerDefinitions.definition(for: language)
            ?? LexerDefinition(language: language.rawValue, rules: [])
        self.init(text: text, definition: definition)
    }

    /// Whether the document produced no symbols.
    public var isEmpty: Bool { symbols.isEmpty }

    /// The symbols that start on a 1-based logical line.
    public func symbols(onLine line: Int) -> [FunctionSymbol] {
        symbols.filter { $0.line == line }
    }

    // MARK: - Extraction

    private struct Candidate {
        let symbol: FunctionSymbol
        let ruleOrder: Int
    }

    private static func extractSymbols(from text: String,
                                       definition: LexerDefinition) -> [FunctionSymbol] {
        let nsText = text as NSString
        guard nsText.length > 0,
              let symbolRules = definition.symbols,
              !symbolRules.isEmpty else {
            return []
        }

        // One line index for the whole pass: every symbol's line is a binary
        // search instead of another full-buffer scan.
        let lineIndex = LineIndex(text)

        let blockSpans = blockCommentSpans(in: nsText, comments: definition.comments)
        let commentSpans = mergedSpans(
            blockSpans
                + lineCommentSpans(in: nsText,
                                   prefix: definition.comments?.linePrefix,
                                   excluding: blockSpans)
        )
        let stringSpans = mergedSpans(matchesForRules(named: ["string"],
                                                      in: text,
                                                      definition: definition))
        let keywordSpans = mergedSpans(matchesForRules(named: ["keyword", "type", "number"],
                                                       in: text,
                                                       definition: definition))

        var candidates: [Candidate] = []
        for (ruleOrder, symbolRule) in symbolRules.enumerated() {
            let matchingRules = definition.rules.filter { $0.name == symbolRule.rule }
            for rule in matchingRules {
                for pattern in rule.patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else {
                        continue
                    }
                    let fullRange = NSRange(location: 0, length: nsText.length)
                    for match in regex.matches(in: text, options: [], range: fullRange)
                    where match.range.length > 0 {
                        guard let (name, nameRange) = symbolName(from: match,
                                                                 in: nsText,
                                                                 kind: symbolRule.kind) else {
                            continue
                        }
                        // Comments and strings win over every symbol rule.
                        guard !overlaps(nameRange, commentSpans),
                              !overlaps(nameRange, stringSpans) else {
                            continue
                        }
                        // A keyword/type/number token at the same location is a
                        // construct, not a declared symbol. Swift initializers
                        // are the one callable keyword worth keeping.
                        if name != "init", overlaps(nameRange, keywordSpans) {
                            continue
                        }

                        let line = lineIndex.line(of: nameRange.location)
                        candidates.append(Candidate(
                            symbol: FunctionSymbol(name: name,
                                                   kind: symbolRule.kind,
                                                   line: line,
                                                   range: nameRange),
                            ruleOrder: ruleOrder
                        ))
                    }
                }
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.symbol.range.location != rhs.symbol.range.location {
                return lhs.symbol.range.location < rhs.symbol.range.location
            }
            if lhs.symbol.range.length != rhs.symbol.range.length {
                return lhs.symbol.range.length > rhs.symbol.range.length
            }
            if lhs.ruleOrder != rhs.ruleOrder {
                return lhs.ruleOrder < rhs.ruleOrder
            }
            return lhs.symbol.name < rhs.symbol.name
        }

        var seenKeys = Set<String>()
        var callableLines = Set<Int>()
        var result: [FunctionSymbol] = []
        for candidate in candidates {
            let symbol = candidate.symbol
            let key = "\(symbol.line)\u{1F}\(symbol.kind.rawValue)\u{1F}\(symbol.name)"
            guard seenKeys.insert(key).inserted else { continue }

            switch symbol.kind {
            case .function, .method:
                guard callableLines.insert(symbol.line).inserted else { continue }
            default:
                break
            }

            result.append(symbol)
        }

        return result
    }

    /// Extracts the display name and absolute UTF-16 range from a rule match.
    private static func symbolName(from match: NSTextCheckingResult,
                                   in text: NSString,
                                   kind: SymbolKind) -> (String, NSRange)? {
        let matched = text.substring(with: match.range) as NSString
        let length = matched.length
        guard length > 0 else { return nil }

        func unit(_ index: Int) -> unichar { matched.character(at: index) }
        func isWhitespace(_ index: Int) -> Bool {
            let character = unit(index)
            return character == 0x20 || character == 0x09
                || character == 0x0A || character == 0x0D
        }

        var start = 0
        var end = length

        switch kind {
        case .section:
            // Drop the leading ATX hashes and whitespace, then an optional
            // closing hash run preceded by whitespace: "## Title ##".
            while start < end, unit(start) == 0x23 { start += 1 }
            while start < end, isWhitespace(start) { start += 1 }
            while end > start, isWhitespace(end - 1) { end -= 1 }
            var hashStart = end
            while hashStart > start, unit(hashStart - 1) == 0x23 { hashStart -= 1 }
            if hashStart < end, hashStart > start, isWhitespace(hashStart - 1) {
                end = hashStart - 1
                while end > start, isWhitespace(end - 1) { end -= 1 }
            }

        case .tag:
            // "<div" or "</div>" -> "div".
            if start < end, unit(start) == 0x3C { start += 1 } // "<"
            if start < end, unit(start) == 0x2F { start += 1 } // "/"
            while end > start, isWhitespace(end - 1) { end -= 1 }
            if end > start, unit(end - 1) == 0x3E { end -= 1 } // ">"

        default:
            while start < end, isWhitespace(start) { start += 1 }
            while end > start, isWhitespace(end - 1) { end -= 1 }

            // Some rules include a declaration keyword before the name
            // (Ruby: "def greet"). Keep the final whitespace-separated token.
            var tokenStart = end
            while tokenStart > start, !isWhitespace(tokenStart - 1) {
                tokenStart -= 1
            }
            if tokenStart > start {
                start = tokenStart
            }

            // Shell's function rule includes the empty parameter list.
            if kind == .function || kind == .method {
                while end > start, unit(end - 1) == 0x28 || unit(end - 1) == 0x29 {
                    end -= 1
                }
                while end > start, isWhitespace(end - 1) { end -= 1 }
            }
        }

        guard end > start else { return nil }
        let localRange = NSRange(location: start, length: end - start)
        let name = matched.substring(with: localRange)
        guard name.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }

        let absoluteRange = NSRange(location: match.range.location + localRange.location,
                                    length: localRange.length)
        return (name, absoluteRange)
    }

    // MARK: - Span helpers

    private static func matchesForRules(named names: [String],
                                        in text: String,
                                        definition: LexerDefinition) -> [NSRange] {
        let nameSet = Set(names)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var spans: [NSRange] = []

        for rule in definition.rules where nameSet.contains(rule.name) {
            for pattern in rule.patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    continue
                }
                for match in regex.matches(in: text, options: [], range: fullRange)
                where match.range.length > 0 {
                    spans.append(match.range)
                }
            }
        }
        return spans
    }

    private static func blockCommentSpans(in text: NSString,
                                          comments: LexerDefinition.CommentSyntax?) -> [NSRange] {
        guard let blockStart = comments?.blockStart,
              let blockEnd = comments?.blockEnd,
              !blockStart.isEmpty,
              !blockEnd.isEmpty else {
            return []
        }

        var spans: [NSRange] = []
        var searchLocation = 0
        let length = text.length
        while searchLocation < length {
            let startRange = text.range(of: blockStart,
                                        options: [],
                                        range: NSRange(location: searchLocation,
                                                       length: length - searchLocation))
            guard startRange.location != NSNotFound else { break }

            let contentStart = NSMaxRange(startRange)
            let endRange = text.range(of: blockEnd,
                                      options: [],
                                      range: NSRange(location: contentStart,
                                                     length: length - contentStart))
            guard endRange.location != NSNotFound else { break }

            spans.append(NSRange(location: startRange.location,
                                 length: NSMaxRange(endRange) - startRange.location))
            searchLocation = NSMaxRange(endRange)
        }
        return spans
    }

    private static func lineCommentSpans(in text: NSString,
                                         prefix: String?,
                                         excluding blockSpans: [NSRange]) -> [NSRange] {
        guard let prefix, !prefix.isEmpty else { return [] }

        var spans: [NSRange] = []
        let prefixLength = prefix.utf16.count
        let prefixFirstUnit = prefix.utf16.first
        let length = text.length
        var index = 0
        var blockIndex = 0

        while index < length {
            while blockIndex < blockSpans.count,
                  NSMaxRange(blockSpans[blockIndex]) <= index {
                blockIndex += 1
            }
            if blockIndex < blockSpans.count {
                let block = blockSpans[blockIndex]
                if block.location <= index, index < NSMaxRange(block) {
                    index = NSMaxRange(block)
                    continue
                }
            }

            if text.character(at: index) == prefixFirstUnit,
               index + prefixLength <= length,
               text.substring(with: NSRange(location: index,
                                            length: prefixLength)) == prefix {
                let newline = text.range(of: "\n",
                                         options: [],
                                         range: NSRange(location: index,
                                                        length: length - index))
                let end = newline.location == NSNotFound ? length : newline.location
                spans.append(NSRange(location: index, length: end - index))
                index = end
            } else {
                index += 1
            }
        }
        return spans
    }

    /// Merges overlapping or adjacent spans and sorts by location. The merged
    /// array is the binary-search target for `overlaps(_:_:)`.
    private static func mergedSpans(_ spans: [NSRange]) -> [NSRange] {
        let sorted = spans.filter { $0.length > 0 }.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length > rhs.length
        }
        var result: [NSRange] = []
        for span in sorted {
            if let last = result.last, span.location <= NSMaxRange(last) {
                let start = min(last.location, span.location)
                let end = max(NSMaxRange(last), NSMaxRange(span))
                result[result.count - 1] = NSRange(location: start, length: end - start)
            } else {
                result.append(span)
            }
        }
        return result
    }

    private static func overlaps(_ range: NSRange, _ spans: [NSRange]) -> Bool {
        guard !spans.isEmpty, range.length > 0 else { return false }
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            let span = spans[mid]
            if NSMaxRange(span) <= range.location {
                low = mid + 1
            } else if span.location >= NSMaxRange(range) {
                high = mid
            } else {
                return true
            }
        }
        return false
    }
}
