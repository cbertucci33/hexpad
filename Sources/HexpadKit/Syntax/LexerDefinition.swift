import Foundation

/// A data-driven description of a language grammar.
///
/// `LexerDefinition` is the serializable grammar description consumed by
/// `SyntaxTokenizer`. Rules are declared in priority order and are compiled in
/// that order; the tokenizer's merge step still resolves overlapping matches by
/// location and length.
///
/// The comment and bracket metadata is intentionally not consumed by the
/// tokenizer yet. It is the groundwork for comment-aware editing and code
/// folding in later slices.
public struct LexerDefinition: Codable, Equatable {

    /// One named rule. `name` is resolved through
    /// `SyntaxTokenizer.tokenTypeByName`, so definitions reuse the token type
    /// mapping that the Swift rule tables already rely on.
    public struct Rule: Codable, Equatable {
        public let name: String
        public let patterns: [String]

        public init(name: String, patterns: [String]) {
            self.name = name
            self.patterns = patterns
        }
    }

    /// Comment syntax metadata. A language may use only line comments, only
    /// block comments, both, or neither.
    public struct CommentSyntax: Codable, Equatable {
        public let linePrefix: String?
        public let blockStart: String?
        public let blockEnd: String?

        public init(linePrefix: String? = nil,
                    blockStart: String? = nil,
                    blockEnd: String? = nil) {
            self.linePrefix = linePrefix
            self.blockStart = blockStart
            self.blockEnd = blockEnd
        }
    }

    /// A bracket pair used for structural matching and folding.
    public struct BracketPair: Codable, Equatable {
        public let open: String
        public let close: String

        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    /// Language name. Matches `Language.rawValue` for languages that have a
    /// tokenizer entry (for example `"JSON"`).
    public let language: String
    public let rules: [Rule]
    public let comments: CommentSyntax?
    public let brackets: [BracketPair]

    public init(language: String,
                rules: [Rule],
                comments: CommentSyntax? = nil,
                brackets: [BracketPair] = []) {
        self.language = language
        self.rules = rules
        self.comments = comments
        self.brackets = brackets
    }

    /// Decodes a definition from its JSON representation.
    public init(json: String) throws {
        self = try JSONDecoder().decode(LexerDefinition.self, from: Data(json.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case rules
        case comments
        case brackets
    }

    /// `comments` and `brackets` are optional in the file format so a compact
    /// definition can omit metadata it does not need.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        comments = try container.decodeIfPresent(CommentSyntax.self, forKey: .comments)
        brackets = try container.decodeIfPresent([BracketPair].self, forKey: .brackets) ?? []
    }
}

/// Registry of every language grammar.
///
/// All highlighted languages live here; `Language.plain` is intentionally
/// absent because it has no rules and tokenizes as a single plain token.
public enum LexerDefinitions {

    /// The grammars resolved by `SyntaxTokenizer`, in `Language` declaration
    /// order.
    public static let dataDriven: [LexerDefinition] = [
        .json,
        .python,
        .javascript,
        .typescript,
        .html,
        .css,
        .markdown,
        .xml,
        .shell,
        .swift
    ]

    private static let byLanguage: [Language: LexerDefinition] = {
        var result: [Language: LexerDefinition] = [:]
        for definition in dataDriven {
            guard let language = Language(rawValue: definition.language) else { continue }
            result[language] = definition
        }
        return result
    }()

    /// Returns the definition for `language`, or `nil` for `Language.plain`.
    public static func definition(for language: Language) -> LexerDefinition? {
        byLanguage[language]
    }
}
