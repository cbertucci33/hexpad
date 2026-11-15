import Foundation
import AppKit

/// Token types for syntax highlighting
public enum TokenType: String {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case variable
    case `operator`
    case punctuation
    case whitespace
    case plain
}

/// Represents a highlighted token
public struct Token: Identifiable {
    /// Derived from the token's range. Syntax tokens never overlap, so the
    /// location is unique; deriving the id avoids allocating a UUID per token.
    public var id: Int { range.location }
    public let type: TokenType
    public let range: NSRange
    public let text: String
}

/// Language identifier
public enum Language: String, CaseIterable, Identifiable {
    case plain = "Plain Text"
    case json = "JSON"
    case python = "Python"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case html = "HTML"
    case css = "CSS"
    case markdown = "Markdown"
    case xml = "XML"
    case shell = "Shell"
    case swift = "Swift"
    
    public var id: String { rawValue }
    
    public static func fromFileName(_ name: String) -> Language {
        let lower = name.lowercased()
        switch lower {
        case let x where x.hasSuffix(".json"): return .json
        case let x where x.hasSuffix(".py"): return .python
        case let x where x.hasSuffix(".js") || x.hasSuffix(".jsx"): return .javascript
        case let x where x.hasSuffix(".ts") || x.hasSuffix(".tsx"): return .typescript
        case let x where x.hasSuffix(".html") || x.hasSuffix(".htm"): return .html
        case let x where x.hasSuffix(".css"): return .css
        case let x where x.hasSuffix(".md"): return .markdown
        case let x where x.hasSuffix(".xml"): return .xml
        case let x where x.hasSuffix(".sh") || x.hasSuffix(".bash") || x.hasSuffix(".zsh"): return .shell
        case let x where x.hasSuffix(".swift"): return .swift
        default: return .plain
        }
    }
}

/// Theme colors for syntax highlighting
public struct Theme {
    public let name: String
    public let colors: [TokenType: NSColor]
    public let background: NSColor
    public let foreground: NSColor
    
    public init(name: String,
                colors: [TokenType: NSColor],
                background: NSColor = .textBackgroundColor,
                foreground: NSColor = .textColor) {
        self.name = name
        self.colors = colors
        self.background = background
        self.foreground = foreground
    }
}

/// Regex-based syntax tokenizer
public final class SyntaxTokenizer {
    
    // MARK: - Language Rule Tables
    
    /// Swift-side rule tables. Languages migrated to
    /// `LexerDefinitions.dataDriven` (currently JSON) are intentionally absent
    /// and resolve through the data-driven loader instead.
    public static let languageRules: [Language: [String: [String]]] = [
        .python: [
            "keyword": [#"\b(def|class|if|elif|else|while|for|in|return|import|from|as|with|try|except|finally|raise|pass|break|continue|and|or|not|is|None|True|False|lambda|yield|global|nonlocal|assert|del)\b"#],
            "string": [#"(?:'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|'[^']*'|\"[^\"]*\")"#],
            "comment": [#"(?m)#[^\n]*"#],
            "number": [#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?j?\b"#],
            "function": [#"\b[a-zA-Z_]\w*(?=\s*\()"#],
            "type": [#"\b(bool|int|float|str|list|dict|tuple|set|None|object|Any|Optional|Union|Type)\b"#]
        ],
        .javascript: [
            "keyword": [#"\b(const|let|var|function|if|else|elif|while|for|do|switch|case|break|continue|return|new|this|class|extends|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|delete|void|typeof)\b"#],
            "string": [#"(?:`[^`]*`|'[^']*'|\"[^\"]*\")"#],
            "comment": [#"(?m)(?:^|[^\\])\/\/[^\n]*|#"(?ms)/\*[\s\S]*?\*/"#],
            "number": [#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?:n)?\b"#],
            "function": [#"\b[a-zA-Z_$]\w*(?=\s*\()"#],
            "type": [#"\b(String|Number|Boolean|Object|Array|Function|Symbol|undefined|null|Promise|Map|Set|WeakMap|WeakSet|RegExp|Date|Error|JSON|Math|console)\b"#],
            "regex": [#"/[^/\n]*[/igmu]*"#]
        ],
        .typescript: [
            "keyword": [#"\b(const|let|var|function|if|else|while|for|switch|case|break|continue|return|new|this|class|extends|interface|type|enum|implements|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|declare|abstract|readonly|as|is|keyof|namespace|module|package)\b"#],
            "string": [#"(?:`[^`]*`|'[^']*'|\"[^\"]*\")"#],
            "comment": [#"(?m)(?:^|[^\\])\/\/[^\n]*|#"(?ms)/\*[\s\S]*?\*/"#],
            "number": [#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?:n)?\b"#],
            "function": [#"\b[a-zA-Z_$]\w*(?=\s*\()"#],
            "type": [#"\b(String|Number|Boolean|Object|Array|Function|Symbol|undefined|null|void|never|any|unknown|true|false|Promise|Map|Set|Partial|Required|Record|Pick|Omit|Exclude|Extract|NonNullable|ReturnType|Parameters|InstanceType)\b"#]
        ],
        .html: [
            "tag": [#"<[a-zA-Z][a-zA-Z0-9]*"#],
            "closing_tag": [#"</[a-zA-Z][a-zA-Z0-9]*>"#],
            "attribute": [#"[a-zA-Z:-][a-zA-Z0-9:-]*(?=\s*=)"#],
            "string": [#""[^"\\]*(?:\\.[^"\\]*)*""#],
            "comment": [#"(?ms)<!--[\s\S]*?-->"#],
            "entity": [#"&[a-zA-Z0-9#];"#]
        ],
        .css: [
            "comment": [#"(?ms)/\*[\s\S]*?\*/"#],
            "selector": [#"[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\s*\{)"#],
            "property": [#"(?m)\s([a-zA-Z-]+)\s*:"#],
            "value": [#"(?<=:)[^;{}]+(?=;)"#],
            "number": [#"\b\d+(?:\.\d+)?(%|px|em|rem|pt|vh|vw|vmin|vmax|deg|rad|turn|s|ms)?\b"#],
            "string": [#""[^"\\]*(?:\\.[^"\\]*)*""#],
            "function": [#"\b[a-zA-Z-]+(?=\()"#]
        ],
        .markdown: [
            "heading": [#"(?m)^#{1,6}\s.*"#],
            "bold": [##"\*\*[^*]+\*\*|##[^#]+##"##],
            "italic": [#"\*[^*]+\*"#],
            "code": [#"`[^`]+`"#],
            "link": [#"\[.+?\]\(.+?\)"#],
            "image": [#"\[[^\]]*\]\([^\)]*\)"#],
            "blockquote": [#"(?m)^\s*>.*"#],
            "list": [#"(?m)^\s*[-*+]\s"#],
            "hrule": [#"(?m)^\s*[-*_]{3,}\s*"#]
        ],
        .xml: [
            "tag": [#"<[a-zA-Z][a-zA-Z0-9]*"#],
            "closing_tag": [#"</[a-zA-Z][a-zA-Z0-9]*>"#],
            "attribute": [#"[a-zA-Z:-][a-zA-Z0-9:-]*(?=\s*=)"#],
            "string": [#""[^"\\]*(?:\\.[^"\\]*)*""#],
            "comment": [#"(?ms)<!--[\s\S]*?-->"#],
            "entity": [#"&[a-zA-Z0-9#];"#]
        ],
        .shell: [
            "keyword": [#"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|select|until|in|time|coproc)\b"#],
            "string": [#"(?:"""[\s\S]*?"""|"[^"\\]*(?:\\.[^"\\]*)*")"#],
            "comment": [#"(?m)#[^\n]*"#],
            "number": [#"\b\d+\b"#],
            "variable": [#"\$\{?[\w@#*?!$]+\}?"#],
            "function": [#"\b[a-zA-Z_][\w]*\s*\(\)"#],
            "operator": [#"[|&;<>`=\]"#]
        ],
        .swift: [
            "keyword": [#"\b(func|let|var|if|else|guard|for|while|switch|case|return|class|struct|enum|protocol|extension|import|public|private|internal|static|final|override|init|deinit|self|nil|try|catch|throw|throws|async|await|defer|where|in|is|as|some|any)\b"#],
            "string": [#"(?:"""[\s\S]*?"""|"[^"\\]*(?:\\.[^"\\]*)*")"#],
            "comment": [#"(?m)(?:^|[^\\])\/\/[^\n]*|(?ms)\/\*[\s\S]*?\*\/"#],
            "number": [#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#],
            "type": [#"\b(Int|String|Double|Bool|Array|Dictionary|Optional)\b"#],
            "function": [#"\b[a-zA-Z_]\w*(?=\s*\()"#]
        ]
    ]
    
    /// Map rule names to token types. Shared by the Swift rule tables and the
    /// data-driven `LexerDefinitionLoader`.
    static let tokenTypeByName: [String: TokenType] = [
        "keyword": .keyword, "string": .string, "comment": .comment, "number": .number,
        "type": .type, "function": .function, "variable": .variable, "operator": .`operator`,
        "punctuation": .punctuation, "whitespace": .whitespace, "plain": .plain,
        "tag": .keyword, "closing_tag": .keyword, "attribute": .variable, "selector": .type,
        "property": .variable, "value": .string, "entity": .number, "heading": .function,
        "bold": .type, "italic": .type, "code": .string, "link": .variable, "image": .variable,
        "blockquote": .comment, "list": .`operator`, "hrule": .`operator`
    ]

    // MARK: - Compiled Regex Cache

    /// One rule, with its regex compiled exactly once per language.
    /// Internal rather than private so the data-driven loader can build the
    /// same rule set the tokenizer consumes.
    struct CompiledRule {
        let type: TokenType
        let regex: NSRegularExpression
    }

    /// A match gathered from one rule before overlapping matches are resolved.
    private struct Candidate {
        let type: TokenType
        let range: NSRange
    }

    /// NSRegularExpression is documented as thread-safe for matching, so each
    /// language's compiled rule list is built once and shared by every caller.
    private final class RegexCache {
        private let lock = NSLock()
        private var cache: [Language: [CompiledRule]] = [:]

        func rules(for language: Language, make: () -> [CompiledRule]) -> [CompiledRule] {
            lock.lock()
            defer { lock.unlock() }
            if let cached = cache[language] { return cached }
            let built = make()
            cache[language] = built
            return built
        }
    }

    private static let regexCache = RegexCache()

    static func compiledRules(for language: Language) -> [CompiledRule] {
        regexCache.rules(for: language) {
            // Data-driven definitions take precedence; the cache is keyed by
            // language either way, so migrated languages still compile once.
            if let definition = LexerDefinitions.definition(for: language) {
                return LexerDefinitionLoader.compiledRules(from: definition)
            }
            guard let ruleTable = languageRules[language] else { return [] }
            return LexerDefinitionLoader.compiledRules(fromLegacyTable: ruleTable)
        }
    }

    // MARK: - Tokenizing

    /// Tokenize the whole text for a given language.
    public static func tokenize(_ text: String, language: Language) -> [Token] {
        let length = (text as NSString).length
        return tokenize(text, language: language, in: NSRange(location: 0, length: length))
    }

    /// Tokenize only `range` of `text`. Token ranges are absolute offsets into
    /// `text`, so callers can attribute just a viewport without touching the
    /// rest of the buffer.
    public static func tokenize(_ text: String, language: Language, in range: NSRange) -> [Token] {
        switch language {
        case .html, .xml:
            return tokenizeEmbeddedLanguages(text, language: language, in: range)
        default:
            return tokenize(text, rules: compiledRules(for: language), in: range)
        }
    }

    /// Tokenize `range` with an already-compiled rule set. This is the shared
    /// implementation behind both the language entry point and the parity
    /// checks for data-driven definitions.
    static func tokenize(_ text: String, rules: [CompiledRule], in range: NSRange) -> [Token] {
        let nsText = text as NSString
        let length = nsText.length
        guard range.location >= 0, range.length >= 0,
              range.location <= length,
              range.length <= length - range.location else {
            return []
        }

        guard !rules.isEmpty else {
            // Plain text: one token covering the requested range.
            return [Token(type: .plain, range: range, text: nsText.substring(with: range))]
        }
        guard range.length > 0 else { return [] }

        // Collect each rule's matches once over the whole requested range, then
        // merge them in document order. This replaces the old O(tokens × rules)
        // loop, which recompiled every regex and rescanned the remainder of the
        // document at every token boundary.
        var candidates: [Candidate] = []
        for rule in rules {
            for match in rule.regex.matches(in: text, options: [], range: range)
            where match.range.length > 0 {
                candidates.append(Candidate(type: rule.type, range: match.range))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return lhs.type.rawValue < rhs.type.rawValue
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(candidates.count * 2 + 2)
        let limit = NSMaxRange(range)
        var cursor = range.location

        for candidate in candidates {
            // A match that starts inside an already-chosen token can only come
            // from a lower-priority construct (keyword inside a string, etc.).
            guard candidate.range.location >= cursor else { continue }
            guard candidate.range.location < limit else { break }

            if candidate.range.location > cursor {
                appendGap(nsText, from: cursor, to: candidate.range.location, into: &tokens)
            }

            let end = min(NSMaxRange(candidate.range), limit)
            let tokenRange = NSRange(location: candidate.range.location, length: end - candidate.range.location)
            tokens.append(Token(type: candidate.type,
                                range: tokenRange,
                                text: nsText.substring(with: tokenRange)))
            cursor = end
        }

        if cursor < limit {
            appendGap(nsText, from: cursor, to: limit, into: &tokens)
        }
        return tokens
    }

    // MARK: - Embedded Languages

    /// A region whose interior is tokenized by a different language.
    private struct EmbeddedRegion {
        let language: Language
        let contentRange: NSRange
    }

    /// Tokenizes HTML/XML documents while delegating `<style>` interiors to the
    /// CSS rules and `<script>` interiors to the JavaScript rules.
    ///
    /// The first pass locates the embedded interiors, skipping HTML comments and
    /// quoted attribute values. The second pass tokenizes each markup gap with
    /// the document language's rules and each interior with the embedded
    /// language's rules. Both rule sets come from `compiledRules(for:)`, so the
    /// regex cache is reused and nothing is recompiled per keystroke.
    private static func tokenizeEmbeddedLanguages(_ text: String,
                                                  language: Language,
                                                  in range: NSRange) -> [Token] {
        let nsText = text as NSString
        let length = nsText.length
        guard range.location >= 0, range.length >= 0,
              range.location <= length,
              range.length <= length - range.location else {
            return []
        }
        let markupRules = compiledRules(for: language)
        guard range.length > 0 else { return [] }

        let regions = embeddedRegions(in: nsText)
        let rangeEnd = NSMaxRange(range)
        var interiors: [(range: NSRange, language: Language)] = []
        for region in regions {
            let start = max(region.contentRange.location, range.location)
            let end = min(NSMaxRange(region.contentRange), rangeEnd)
            if end > start {
                interiors.append((NSRange(location: start, length: end - start),
                                  region.language))
            }
        }

        // Nothing embedded in the requested viewport: keep the plain HTML/XML
        // path byte-for-byte identical.
        guard !interiors.isEmpty else {
            return tokenize(text, rules: markupRules, in: range)
        }

        interiors.sort { $0.range.location < $1.range.location }

        var tokens: [Token] = []
        var cursor = range.location
        for interior in interiors {
            if interior.range.location > cursor {
                let gap = NSRange(location: cursor,
                                  length: interior.range.location - cursor)
                tokens.append(contentsOf: tokenize(text, rules: markupRules, in: gap))
            }
            tokens.append(contentsOf: tokenize(text,
                                               rules: compiledRules(for: interior.language),
                                               in: interior.range))
            cursor = NSMaxRange(interior.range)
        }
        if cursor < rangeEnd {
            let gap = NSRange(location: cursor, length: rangeEnd - cursor)
            tokens.append(contentsOf: tokenize(text, rules: markupRules, in: gap))
        }

        tokens.sort { $0.range.location < $1.range.location }
        return tokens
    }

    /// First pass: finds `<style>` and `<script>` interiors in document order.
    ///
    /// Comments (`<!-- ... -->`), declarations, processing instructions, and
    /// quoted attribute values are skipped, so markup that merely mentions a
    /// tag does not start an embedded region.
    private static func embeddedRegions(in text: NSString) -> [EmbeddedRegion] {
        var regions: [EmbeddedRegion] = []
        let length = text.length
        var index = 0

        while index < length {
            let searchRange = NSRange(location: index, length: length - index)
            let tagStart = text.range(of: "<", options: [], range: searchRange)
            guard tagStart.location != NSNotFound else { break }
            let start = tagStart.location

            if hasPrefix("<!--", in: text, at: start) {
                let commentContent = start + 4
                let rest = NSRange(location: commentContent, length: length - commentContent)
                let close = text.range(of: "-->", options: [], range: rest)
                index = close.location == NSNotFound ? length : NSMaxRange(close)
                continue
            }

            if start + 1 < length {
                let marker = text.character(at: start + 1)
                if marker == 0x21 /* ! */ || marker == 0x3F /* ? */ {
                    index = endOfTag(in: text, from: start + 2)
                    continue
                }
                if marker == 0x2F /* / */ {
                    index = endOfTag(in: text, from: start + 2)
                    continue
                }
            }

            guard let nameRange = tagNameRange(in: text, at: start) else {
                index = start + 1
                continue
            }
            let name = text.substring(with: nameRange).lowercased()
            let tagEnd = endOfTag(in: text, from: NSMaxRange(nameRange))
            guard tagEnd > start else { index = length; break }

            // A slash immediately before `>` marks a self-closing tag, which
            // has no embedded interior.
            let closeBracket = tagEnd - 1
            var last = closeBracket - 1
            while last > start && isWhitespace(text.character(at: last)) {
                last -= 1
            }
            let selfClosing = last > start && text.character(at: last) == 0x2F

            if (name == "style" || name == "script") && !selfClosing {
                let embeddedLanguage: Language = name == "style" ? .css : .javascript
                let closing = closingTag(in: text, named: name, from: tagEnd)
                if let closing {
                    let contentLength = closing.location - tagEnd
                    if contentLength > 0 {
                        regions.append(EmbeddedRegion(
                            language: embeddedLanguage,
                            contentRange: NSRange(location: tagEnd, length: contentLength)
                        ))
                    }
                    index = NSMaxRange(closing)
                } else {
                    if tagEnd < length {
                        regions.append(EmbeddedRegion(
                            language: embeddedLanguage,
                            contentRange: NSRange(location: tagEnd, length: length - tagEnd)
                        ))
                    }
                    index = length
                }
                continue
            }

            index = tagEnd
        }

        return regions
    }

    private static func hasPrefix(_ prefix: String, in text: NSString, at location: Int) -> Bool {
        let prefixLength = (prefix as NSString).length
        guard location >= 0, location + prefixLength <= text.length else { return false }
        return text.compare(prefix,
                            options: [],
                            range: NSRange(location: location, length: prefixLength)) == .orderedSame
    }

    private static func tagNameRange(in text: NSString, at start: Int) -> NSRange? {
        var index = start + 1
        guard index < text.length, isLetter(text.character(at: index)) else { return nil }
        index += 1
        while index < text.length {
            let character = text.character(at: index)
            guard isLetter(character) || isDigit(character)
                    || character == 0x2D /* - */ || character == 0x3A /* : */ else {
                break
            }
            index += 1
        }
        return NSRange(location: start + 1, length: index - (start + 1))
    }

    /// Returns the offset just past the tag's closing `>`, ignoring `>` inside
    /// single- or double-quoted attribute values.
    private static func endOfTag(in text: NSString, from start: Int) -> Int {
        var index = start
        var quote: unichar = 0
        while index < text.length {
            let character = text.character(at: index)
            if quote != 0 {
                if character == quote { quote = 0 }
            } else if character == 0x22 /* " */ || character == 0x27 /* ' */ {
                quote = character
            } else if character == 0x3E /* > */ {
                return index + 1
            }
            index += 1
        }
        return text.length
    }

    /// Finds the `</name ...>` that closes an embedded block, case-insensitively,
    /// and returns its full range (including the closing `>`).
    private static func closingTag(in text: NSString, named name: String, from start: Int) -> NSRange? {
        let needle = "</" + name
        let length = text.length
        var searchStart = start
        while searchStart < length {
            let searchRange = NSRange(location: searchStart, length: length - searchStart)
            let match = text.range(of: needle, options: .caseInsensitive, range: searchRange)
            guard match.location != NSNotFound else { return nil }
            let afterName = NSMaxRange(match)
            if afterName < length {
                let character = text.character(at: afterName)
                if character == 0x3E /* > */ {
                    return NSRange(location: match.location,
                                   length: afterName + 1 - match.location)
                }
                if character == 0x2F /* / */ || isWhitespace(character) {
                    let end = endOfTag(in: text, from: afterName)
                    return NSRange(location: match.location, length: end - match.location)
                }
            } else {
                return NSRange(location: match.location, length: length - match.location)
            }
            searchStart = afterName
        }
        return nil
    }

    private static func isLetter(_ character: unichar) -> Bool {
        (character >= 0x41 && character <= 0x5A) || (character >= 0x61 && character <= 0x7A)
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    /// Emits the unmatched run between two matches as one token instead of one
    /// token per character.
    private static func appendGap(_ text: NSString,
                                  from location: Int,
                                  to end: Int,
                                  into tokens: inout [Token]) {
        guard end > location else { return }
        let range = NSRange(location: location, length: end - location)
        var onlyWhitespace = true
        for index in location..<end {
            let character = text.character(at: index)
            if character != 0x20 && character != 0x09 && character != 0x0A && character != 0x0D {
                onlyWhitespace = false
                break
            }
        }
        tokens.append(Token(type: onlyWhitespace ? .whitespace : .plain,
                            range: range,
                            text: text.substring(with: range)))
    }

    /// Get highlight color for a token type in a theme
    public static func color(for type: TokenType, theme: Theme) -> NSColor {
        return theme.colors[type] ?? theme.foreground
    }
}
