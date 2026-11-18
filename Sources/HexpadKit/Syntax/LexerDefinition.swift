import Foundation

/// The kind of document symbol an outline entry represents.
///
/// Symbol kinds are deliberately coarse: they describe the role a construct
/// plays in a document outline, not its exact language-specific spelling. A
/// Swift `func`, a Python `def`, and a C function all end up as `.function` or
/// `.method`; a Markdown heading becomes a `.section`.
public enum SymbolKind: String, Codable, CaseIterable {
    /// A free function or top-level callable.
    case function
    /// A callable that normally lives inside a type or object.
    case method
    /// A stored or computed property. Declared for completeness; the current
    /// lexer rules only expose callables and document structure.
    case property
    /// A named type (class, struct, enum, protocol, interface, and so on).
    case type
    /// A document section, such as a Markdown heading.
    case section
    /// A CSS selector.
    case selector
    /// A markup element name.
    case tag
    /// A markup attribute name.
    case attribute
}

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

    /// Declares that matches of an existing highlighting rule are document
    /// outline symbols.
    ///
    /// The mapping reuses the grammar instead of duplicating it: the outline
    /// runs the named rule's regexes over the document, so a language's notion
    /// of a function or heading cannot drift from what it highlights. The rule
    /// name is resolved against `rules`; a definition may declare several
    /// symbol rules and may map the same rule to only one kind.
    public struct SymbolRule: Codable, Equatable {

        /// Name of a rule in `rules` whose matches become symbols.
        public let rule: String

        /// The outline kind assigned to those matches.
        public let kind: SymbolKind

        public init(rule: String, kind: SymbolKind) {
            self.rule = rule
            self.kind = kind
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
    /// Which highlighting rules participate in the document outline. `nil`
    /// (or an empty list) means the language has no meaningful symbols, so the
    /// function-list model produces an empty outline.
    public let symbols: [SymbolRule]?

    public init(language: String,
                rules: [Rule],
                comments: CommentSyntax? = nil,
                brackets: [BracketPair] = [],
                foldableRangeRules: [FoldableRangeRule] = [],
                symbols: [SymbolRule]? = nil) {
        self.language = language
        self.rules = rules
        self.comments = comments
        self.brackets = brackets
        self.foldableRangeRules = foldableRangeRules
        self.symbols = symbols
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
        case symbols
    }

    /// `comments`, `brackets`, `foldableRangeRules`, and `symbols` are optional
    /// in the file format so a compact definition can omit metadata it does not
    /// need.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        comments = try container.decodeIfPresent(CommentSyntax.self, forKey: .comments)
        brackets = try container.decodeIfPresent([BracketPair].self, forKey: .brackets) ?? []
        foldableRangeRules = try container.decodeIfPresent([FoldableRangeRule].self,
                                                           forKey: .foldableRangeRules) ?? []
        symbols = try container.decodeIfPresent([SymbolRule].self, forKey: .symbols)
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
        .swift,
        .c,
        .cpp,
        .csharp,
        .java,
        .kotlin,
        .ruby,
        .go,
        .rust,
        .php,
        .sql,
        .yaml,
        .toml,
        .ini,
        .lua,
        .r,
        .perl,
        .matlab,
        .haskell,
        .scala,
        .clojure,
        .dart,
        .ocaml,
        .erlang,
        .racket,
        .fsharp,
        .groovy,
        .nim,
        .zig,
        .batch,
        .cmake,
        .makefile,
        .powershell,
        .latex,
        .objectivec,
        .pascal,
        .ada,
        .diff,
        .properties
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
