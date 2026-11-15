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
    
    public static let languageRules: [Language: [String: [String]]] = [
        .json: [
            "keyword": [#"true"#, #"false"#, #"null"#],
            "string": [#""[^"\\]*(?:\\.[^"\\]*)*""#],
            "number": [#"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#],
            "punctuation": [#"[{}\[\],:]"#]
        ],
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
    
    /// Map rule dictionary keys to token types
    private static let tokenTypeByName: [String: TokenType] = [
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
    private struct CompiledRule {
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

    private static func compiledRules(for language: Language) -> [CompiledRule] {
        regexCache.rules(for: language) {
            guard let ruleTable = languageRules[language] else { return [] }
            // Dictionary iteration order is not stable; sorting the rule names
            // keeps tie-breaking deterministic across runs and processes.
            return ruleTable.keys.sorted().flatMap { name -> [CompiledRule] in
                guard let type = tokenTypeByName[name],
                      let patterns = ruleTable[name] else { return [] }
                return patterns.compactMap { pattern in
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                        return nil
                    }
                    return CompiledRule(type: type, regex: regex)
                }
            }
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
        let nsText = text as NSString
        let length = nsText.length
        guard range.location >= 0, range.length >= 0,
              range.location <= length,
              range.length <= length - range.location else {
            return []
        }

        let rules = compiledRules(for: language)
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
