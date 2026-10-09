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
    public let id = UUID()
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
        "punctuation": .punctuation, "whitespace": .whitespace, "plain": .plain
    ]

    /// Tokenize text for a given language
    public static func tokenize(_ text: String, language: Language) -> [Token] {
        guard let rules = languageRules[language], !rules.isEmpty else {
            return [Token(type: .plain, range: NSRange(location: 0, length: text.count), text: text)]
        }
        
        var tokens: [Token] = []
        var location = 0
        let textCount = text.count
        
        while location < textCount {
            var bestMatch: (type: TokenType, range: NSRange, text: String, length: Int)?
            
            for (name, patterns) in rules {
                guard let type = tokenTypeByName[name] else { continue }
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                          let match = regex.firstMatch(in: text, options: [],
                                                       range: NSRange(location: location, length: textCount - location)) else {
                        continue
                    }
                    
                    if bestMatch == nil || match.range.location < bestMatch!.range.location {
                        let matchedText = String(text[text.index(text.startIndex, offsetBy: match.range.location)..<text.index(text.startIndex, offsetBy: match.range.location + match.range.length)])
                        bestMatch = (type, match.range, matchedText, match.range.length)
                    }
                }
            }
            
            if let match = bestMatch {
                // Add whitespace/plain token before match
                if match.range.location > location {
                    let beforeText = String(text[text.index(text.startIndex, offsetBy: location)..<text.index(text.startIndex, offsetBy: match.range.location)])
                    tokens.append(Token(type: .whitespace, range: NSRange(location: location, length: match.range.location - location), text: beforeText))
                }
                
                tokens.append(Token(type: match.type, range: match.range, text: match.text))
                location = match.range.location + match.range.length
            } else {
                // Plain text character
                tokens.append(Token(type: .plain, range: NSRange(location: location, length: 1), text: String(text[text.index(text.startIndex, offsetBy: location)])))
                location += 1
            }
        }
        
        return tokens
    }
    
    /// Get highlight color for a token type in a theme
    public static func color(for type: TokenType, theme: Theme) -> NSColor {
        return theme.colors[type] ?? theme.foreground
    }
}
