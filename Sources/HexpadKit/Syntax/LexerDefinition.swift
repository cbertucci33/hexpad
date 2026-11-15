import Foundation

/// A data-driven description of a language grammar.
///
/// `LexerDefinition` is the serializable grammar description consumed by
/// `SyntaxTokenizer`. Rules are declared in priority order and are compiled in
/// that order; the tokenizer's merge step still resolves overlapping matches by
/// location and length.
///
/// The comment and bracket metadata is not consumed by the tokenizer: it
/// describes editing structure (comment toggling, folding) rather than
/// highlighting. `FoldModel` reads `comments` and `brackets`; the
/// `foldableRangeRules` extension covers constructs neither can express.
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

    /// A foldable construct that comment and bracket metadata cannot express.
    ///
    /// Most languages fold by bracket pairs and block comments alone. Markdown
    /// does not: its foldable unit is a heading section, which starts on a
    /// heading line and runs to just before the next heading of the same or a
    /// shallower level. A bracket pair cannot describe that because the closing
    /// delimiter depends on the heading level, so the definition names the
    /// construct instead of trying to force it into `BracketPair`.
    ///
    /// `FoldModel` does not consume this field yet; it is the definition-side
    /// extension point that a heading-aware fold pass can read without changing
    /// the comment/bracket metadata format.
    public struct FoldableRangeRule: Codable, Equatable {

        /// The kind of line-oriented construct the rule opens.
        public enum Kind: String, Codable {
            /// A Markdown ATX heading section (`#` through `######`). The fold
            /// starts at the heading line and ends at the last line before the
            /// next heading of the same or a shallower level, or at the end of
            /// the document.
            case headingSection
        }

        public let kind: Kind

        /// Regex matching the line that opens the construct. It is the same
        /// expression the definition's highlighting rule uses, so the fold and
        /// highlight notions of a heading cannot drift apart.
        public let startPattern: String

        public init(kind: Kind, startPattern: String) {
            self.kind = kind
            self.startPattern = startPattern
        }
    }

    /// Language name. Matches `Language.rawValue` for languages that have a
    /// tokenizer entry (for example `"JSON"`).
    public let language: String
    public let rules: [Rule]
    public let comments: CommentSyntax?
    public let brackets: [BracketPair]
    /// Line-oriented fold constructs that brackets and comments cannot describe.
    /// Empty for every language except Markdown.
    public let foldableRangeRules: [FoldableRangeRule]

    public init(language: String,
                rules: [Rule],
                comments: CommentSyntax? = nil,
                brackets: [BracketPair] = [],
                foldableRangeRules: [FoldableRangeRule] = []) {
        self.language = language
        self.rules = rules
        self.comments = comments
        self.brackets = brackets
        self.foldableRangeRules = foldableRangeRules
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
        case foldableRangeRules
    }

    /// `comments`, `brackets`, and `foldableRangeRules` are optional in the
    /// file format so a compact definition can omit metadata it does not need.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        comments = try container.decodeIfPresent(CommentSyntax.self, forKey: .comments)
        brackets = try container.decodeIfPresent([BracketPair].self, forKey: .brackets) ?? []
        foldableRangeRules = try container.decodeIfPresent([FoldableRangeRule].self,
                                                           forKey: .foldableRangeRules) ?? []
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
