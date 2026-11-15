import XCTest
@testable import HexpadKit

final class LexerDefinitionTests: XCTestCase {

    /// The pre-migration JSON table, copied verbatim from
    /// `SyntaxTokenizer.languageRules` so the data-driven path can be compared
    /// against the dictionary path it replaced.
    private let legacyJSONRules: [String: [String]] = [
        "keyword": [#"true"#, #"false"#, #"null"#],
        "string": [#""[^"\\]*(?:\\.[^"\\]*)*""#],
        "number": [#"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#],
        "punctuation": [#"[{}\[\],:]"#]
    ]

    /// The pre-migration Swift rule tables, copied from
    /// `SyntaxTokenizer.languageRules` before slice S-P8b removed it.
    ///
    /// These fixtures are the "before" side of the per-language token-parity
    /// checks: they are compiled and tokenized exactly the way the tokenizer
    /// used to consume them.
    ///
    /// Contract change (cards c8028c4b / 8416808d): the JavaScript and
    /// TypeScript `comment` entries no longer carry the stray `#"` literal that
    /// disabled block-comment highlighting, and the inert JavaScript `regex`
    /// entry was removed. The fixtures mirror the corrected grammars so the
    /// parity checks still describe the shipped rules.
    private let legacyRules: [Language: [String: [String]]] = [
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
            "comment": [#"(?m)(?:^|[^\\])\/\/[^\n]*|(?ms)/\*[\s\S]*?\*/"#],
            "number": [#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?:n)?\b"#],
            "function": [#"\b[a-zA-Z_$]\w*(?=\s*\()"#],
            "type": [#"\b(String|Number|Boolean|Object|Array|Function|Symbol|undefined|null|Promise|Map|Set|WeakMap|WeakSet|RegExp|Date|Error|JSON|Math|console)\b"#]
        ],
        .typescript: [
            "keyword": [#"\b(const|let|var|function|if|else|while|for|switch|case|break|continue|return|new|this|class|extends|interface|type|enum|implements|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|declare|abstract|readonly|as|is|keyof|namespace|module|package)\b"#],
            "string": [#"(?:`[^`]*`|'[^']*'|\"[^\"]*\")"#],
            "comment": [#"(?m)(?:^|[^\\])\/\/[^\n]*|(?ms)/\*[\s\S]*?\*/"#],
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
            "bold": [#"\*\*[^*]+\*\*|##[^#]+##"#],
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

    /// Small representative source per language. HTML and XML samples include
    /// embedded `<style>`/`<script>` blocks so the parity check also exercises
    /// the rules the embedded-language pass borrows.
    private let samples: [Language: String] = [
        .python: "# comment\ndef greet(name):\n    if name is None:\n        return \"hello\" + str(42)\n",
        .javascript: "// comment\nconst greet = (name) => {\n    /* block */\n    return `hello ${name}` + 42;\n};\n",
        .typescript: "// comment\ninterface User { name: string; }\nconst greet = (user: User): string => {\n    return `hi ${user.name}`;\n};\n",
        .html: "<div class=\"box\">Hello &amp; welcome</div>\n<style>.card { color: red; }</style>\n<script>const x = 1;</script>\n",
        .css: "/* comment */\n.card { color: red; margin: 0px; }\n#id { padding: 1.5em; }\n",
        .markdown: "# Title\n**bold** and *italic* and `code`\n\n- item\n> quote\n[link](https://example.com)\n",
        .xml: "<?xml version=\"1.0\"?>\n<root id=\"main\"><child>text &amp; more</child></root>\n",
        .shell: "#!/bin/bash\nif [ \"$x\" = 1 ]; then\n  echo \"hello $USER\"\nfi\n",
        .swift: "// comment\nfunc greet(name: String) -> Bool {\n    let count = 42\n    return name == \"world\"\n}\n"
    ]

    private struct TokenSnapshot: Equatable {
        let type: TokenType
        let range: NSRange
        let text: String

        init(_ token: Token) {
            type = token.type
            range = token.range
            text = token.text
        }
    }

    // MARK: - Decoding

    func testEmbeddedJSONDefinitionDecodes() throws {
        let decoded = try LexerDefinition(json: LexerDefinition.jsonSource)

        XCTAssertEqual(decoded.language, "JSON")
        XCTAssertEqual(decoded.rules.map(\.name), ["keyword", "number", "punctuation", "string"])
        XCTAssertEqual(decoded.rules.first?.patterns, ["true", "false", "null"])
        XCTAssertEqual(decoded, LexerDefinition.json)
    }

    func testDecodedJSONPatternsMatchLegacyTable() {
        let decoded = LexerDefinition.json
        var decodedTable: [String: [String]] = [:]
        for rule in decoded.rules {
            decodedTable[rule.name] = rule.patterns
        }
        XCTAssertEqual(decodedTable, legacyJSONRules)
    }

    /// Every embedded source must decode, and its rules must be the exact
    /// patterns and rule names the Swift dictionary held before migration.
    func testDecodedDefinitionsMatchLegacyTables() {
        for (language, table) in legacyRules {
            guard let definition = LexerDefinitions.definition(for: language) else {
                XCTFail("\(language.rawValue) has no embedded definition")
                continue
            }
            var decodedTable: [String: [String]] = [:]
            for rule in definition.rules {
                decodedTable[rule.name] = rule.patterns
            }
            XCTAssertEqual(decodedTable, table,
                           "\(language.rawValue) definition drifted from the legacy table")
        }
    }

    // MARK: - Metadata

    func testJSONMetadataRoundTrips() throws {
        let definition = LexerDefinition.json

        XCTAssertNil(definition.comments, "JSON has no line or block comment syntax")
        XCTAssertEqual(definition.brackets, [
            LexerDefinition.BracketPair(open: "{", close: "}"),
            LexerDefinition.BracketPair(open: "[", close: "]")
        ])

        let decoded = try JSONDecoder().decode(LexerDefinition.self,
                                               from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded, definition)
        XCTAssertNil(decoded.comments)
        XCTAssertEqual(decoded.brackets, definition.brackets)
        XCTAssertEqual(decoded.language, "JSON")
    }

    func testCommentMetadataRoundTrips() throws {
        let definition = LexerDefinition(
            language: "Sample",
            rules: [.init(name: "keyword", patterns: ["let"])],
            comments: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
            brackets: [.init(open: "(", close: ")")]
        )

        let decoded = try JSONDecoder().decode(LexerDefinition.self,
                                               from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded, definition)
        XCTAssertEqual(decoded.comments?.linePrefix, "//")
        XCTAssertEqual(decoded.comments?.blockStart, "/*")
        XCTAssertEqual(decoded.comments?.blockEnd, "*/")
        XCTAssertEqual(decoded.brackets, [.init(open: "(", close: ")")])
    }

    // MARK: - Loader parity

    func testLoaderCompilesDefinitionRulesInPriorityOrder() {
        let rules = LexerDefinitionLoader.compiledRules(from: LexerDefinition.json)
        let legacyRules = LexerDefinitionLoader.compiledRules(fromLegacyTable: legacyJSONRules)

        XCTAssertEqual(rules.count, legacyRules.count)
        XCTAssertEqual(rules.map(\.type), [
            .keyword, .keyword, .keyword,
            .number,
            .punctuation,
            .string
        ])
        XCTAssertEqual(rules.map(\.regex.pattern), legacyRules.map(\.regex.pattern))
    }

    func testLoaderProducesEquivalentTokensToLegacyDictionaryPath() {
        let source = #"""
        {
          "name": "hexpad",
          "enabled": true,
          "count": -42.5e+3,
          "nothing": null,
          "literals": "true false null",
          "escaped": "a \"quoted\" word",
          "nested": {"items": [1, 2, 3]}
        }
        """#
        let range = NSRange(location: 0, length: (source as NSString).length)

        let legacyTokens = SyntaxTokenizer.tokenize(
            source,
            rules: LexerDefinitionLoader.compiledRules(fromLegacyTable: legacyJSONRules),
            in: range
        )
        let definitionTokens = SyntaxTokenizer.tokenize(source, language: .json)

        XCTAssertFalse(definitionTokens.isEmpty)
        XCTAssertEqual(definitionTokens.map(TokenSnapshot.init),
                       legacyTokens.map(TokenSnapshot.init))

        // Whole-document coverage: the data path must not drop or overlap text.
        XCTAssertEqual(definitionTokens.reduce(0) { $0 + $1.range.length }, range.length)

        let types = Set(definitionTokens.map(\.type))
        XCTAssertTrue(types.contains(.keyword))
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.contains(.number))
        XCTAssertTrue(types.contains(.punctuation))
        XCTAssertTrue(types.contains(.whitespace))

        // A keyword inside a string must stay part of the string token.
        let literals = definitionTokens.first { $0.text.contains("true false null") }
        XCTAssertEqual(literals?.type, .string)
    }

    // MARK: - Registry wiring

    func testEveryLanguageResolvesThroughTheDataDrivenPath() {
        let definitionLanguages = Set(LexerDefinitions.dataDriven.map(\.language))
        let highlightedLanguages = Set(Language.allCases
            .filter { $0 != .plain }
            .map(\.rawValue))

        XCTAssertEqual(definitionLanguages, highlightedLanguages,
                       "every non-plain Language must have a definition")
        XCTAssertEqual(LexerDefinitions.dataDriven.count, highlightedLanguages.count)

        for language in Language.allCases {
            if language == .plain {
                XCTAssertNil(LexerDefinitions.definition(for: .plain),
                             "plain must not gain a grammar")
                continue
            }

            guard let definition = LexerDefinitions.definition(for: language) else {
                XCTFail("\(language.rawValue) does not resolve through the data-driven path")
                continue
            }
            XCTAssertEqual(definition.language, language.rawValue)
            XCTAssertFalse(definition.rules.isEmpty,
                           "\(language.rawValue) has an empty definition")
            XCTAssertFalse(SyntaxTokenizer.compiledRules(for: language).isEmpty,
                           "\(language.rawValue) compiled no rules")
        }
    }

    func testUnmappedRuleNameStaysInert() {
        // Contract change (card 8416808d): JavaScript's inert "regex" rule was
        // removed from the definition rather than mapped, because mapping it to
        // an existing token type would highlight `/` division and comment text
        // as regex literals. The loader still skips any unmapped rule name, so
        // keep that guarantee covered with a synthetic definition.
        XCTAssertNil(SyntaxTokenizer.tokenTypeByName["regex"])

        let definition = LexerDefinition(
            language: "Sample",
            rules: [
                .init(name: "regex", patterns: [#"/[^/\n]*[/igmu]*"#]),
                .init(name: "keyword", patterns: [#"\blet\b"#])
            ]
        )
        XCTAssertEqual(LexerDefinitionLoader.compiledRules(from: definition).map(\.type),
                       [.keyword],
                       "an unmapped rule name must not compile into a token rule")
    }

    // MARK: - JavaScript/TypeScript regressions

    func testJavaScriptAndTypeScriptBlockCommentPatternsHaveNoRawLiteralArtifact() throws {
        for language in [Language.javascript, .typescript] {
            let definition = try XCTUnwrap(LexerDefinitions.definition(for: language))
            let comment = try XCTUnwrap(definition.rules.first { $0.name == "comment" },
                                        "\(language.rawValue) has no comment rule")
            XCTAssertEqual(comment.patterns,
                           [#"(?m)(?:^|[^\\])\/\/[^\n]*|(?ms)/\*[\s\S]*?\*/"#],
                           "\(language.rawValue) comment rule still carries the #\" artifact")
        }
    }

    func testJavaScriptDefinitionHasNoInertRegexRule() throws {
        // Contract change (card 8416808d): the JS regex-literal rule never had
        // a token type and could not be made useful without a new TokenType, so
        // it was deleted instead of left as dead data.
        let definition = try XCTUnwrap(LexerDefinitions.definition(for: .javascript))
        XCTAssertFalse(definition.rules.contains { $0.name == "regex" })
    }

    func testCompiledRulesForLanguageComeFromTheDefinition() {
        for definition in LexerDefinitions.dataDriven {
            guard let language = Language(rawValue: definition.language) else {
                XCTFail("definition language \(definition.language) is not a Language case")
                continue
            }
            let expected = LexerDefinitionLoader.compiledRules(from: definition)
            XCTAssertEqual(SyntaxTokenizer.compiledRules(for: language).map(\.regex.pattern),
                           expected.map(\.regex.pattern),
                           "\(language.rawValue) did not resolve through its definition")
        }
    }

    func testPlainLanguageStillHasNoRules() {
        XCTAssertNil(LexerDefinitions.definition(for: .plain))
        XCTAssertTrue(SyntaxTokenizer.compiledRules(for: .plain).isEmpty)

        let source = "hello world\n"
        let tokens = SyntaxTokenizer.tokenize(source, language: .plain)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.type, .plain)
        XCTAssertEqual(tokens.first?.text, source)
        XCTAssertEqual(tokens.first?.range,
                       NSRange(location: 0, length: (source as NSString).length))
    }

    // MARK: - Per-language token parity

    func testPythonTokenParity() { assertTokenParity(.python) }
    func testJavaScriptTokenParity() { assertTokenParity(.javascript) }
    func testTypeScriptTokenParity() { assertTokenParity(.typescript) }
    func testHTMLTokenParity() { assertTokenParity(.html) }
    func testCSSTokenParity() { assertTokenParity(.css) }
    func testMarkdownTokenParity() { assertTokenParity(.markdown) }
    func testXMLTokenParity() { assertTokenParity(.xml) }
    func testShellTokenParity() { assertTokenParity(.shell) }
    func testSwiftTokenParity() { assertTokenParity(.swift) }

    /// Tokenizes the language's sample both ways: with the pre-migration rule
    /// table (through the legacy loader) and with the migrated definition (the
    /// production path). The snapshots must match token for token.
    private func assertTokenParity(_ language: Language,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        guard let table = legacyRules[language],
              let definition = LexerDefinitions.definition(for: language),
              let source = samples[language] else {
            XCTFail("missing fixture for \(language.rawValue)", file: file, line: line)
            return
        }

        let range = NSRange(location: 0, length: (source as NSString).length)
        let before = SyntaxTokenizer.tokenize(
            source,
            rules: LexerDefinitionLoader.compiledRules(fromLegacyTable: table),
            in: range
        )
        let after = SyntaxTokenizer.tokenize(
            source,
            rules: LexerDefinitionLoader.compiledRules(from: definition),
            in: range
        )
        // The production entry point must be wired to the same rules.
        let production = SyntaxTokenizer.tokenize(
            source,
            rules: SyntaxTokenizer.compiledRules(for: language),
            in: range
        )

        XCTAssertFalse(before.isEmpty, "\(language.rawValue) sample produced no tokens",
                       file: file, line: line)
        XCTAssertEqual(after.map(TokenSnapshot.init), before.map(TokenSnapshot.init),
                       "\(language.rawValue) tokens changed after migration",
                       file: file, line: line)
        XCTAssertEqual(production.map(TokenSnapshot.init), before.map(TokenSnapshot.init),
                       "\(language.rawValue) production rules differ from its definition",
                       file: file, line: line)

        // Ranges must cover the whole sample exactly once.
        XCTAssertEqual(after.reduce(0) { $0 + $1.range.length }, range.length,
                       "\(language.rawValue) tokens do not cover the sample",
                       file: file, line: line)
        XCTAssertEqual(after.map(\.text).joined(), source, file: file, line: line)
    }
}
