import XCTest
@testable import HexpadKit

/// Metadata coverage for the data-driven definitions.
///
/// These tests describe the editing structure of each language (comments,
/// bracket pairs, and Markdown's heading folds) rather than its highlighting.
/// `LexerDefinitionTests` remains the guard that the regex rules are unchanged.
final class LexerDefinitionMetadataTests: XCTestCase {

    // MARK: - Fixtures

    /// Expected comment syntax per language. JSON is absent because JSON has
    /// no comment form at all and therefore keeps `comments` nil.
    private let expectedComments: [Language: LexerDefinition.CommentSyntax] = [
        .python: .init(linePrefix: "#"),
        .javascript: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .typescript: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .html: .init(blockStart: "<!--", blockEnd: "-->"),
        .css: .init(blockStart: "/*", blockEnd: "*/"),
        .markdown: .init(blockStart: "<!--", blockEnd: "-->"),
        .xml: .init(blockStart: "<!--", blockEnd: "-->"),
        .shell: .init(linePrefix: "#"),
        .swift: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .c: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .cpp: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .csharp: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .java: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .kotlin: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .ruby: .init(linePrefix: "#", blockStart: "=begin", blockEnd: "=end"),
        .go: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .rust: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .php: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .sql: .init(linePrefix: "--", blockStart: "/*", blockEnd: "*/"),
        .yaml: .init(linePrefix: "#"),
        .toml: .init(linePrefix: "#"),
        .ini: .init(linePrefix: ";"),
        .lua: .init(linePrefix: "--", blockStart: "--[[", blockEnd: "]]"),
        .r: .init(linePrefix: "#"),
        .perl: .init(linePrefix: "#", blockStart: "=pod", blockEnd: "=cut"),
        .matlab: .init(linePrefix: "%", blockStart: "%{", blockEnd: "%}"),
        .haskell: .init(linePrefix: "--", blockStart: "{-", blockEnd: "-}"),
        .scala: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .clojure: .init(linePrefix: ";"),
        .dart: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .ocaml: .init(blockStart: "(*", blockEnd: "*)"),
        .erlang: .init(linePrefix: "%"),
        .racket: .init(linePrefix: ";", blockStart: "#|", blockEnd: "|#"),
        .fsharp: .init(linePrefix: "//", blockStart: "(*", blockEnd: "*)"),
        .groovy: .init(linePrefix: "//", blockStart: "/*", blockEnd: "*/"),
        .nim: .init(linePrefix: "#", blockStart: "#[", blockEnd: "]#"),
        .zig: .init(linePrefix: "//"),
        .batch: .init(linePrefix: "rem "),
        .cmake: .init(linePrefix: "#"),
        .makefile: .init(linePrefix: "#"),
        .powershell: .init(linePrefix: "#", blockStart: "<#", blockEnd: "#>"),
        .latex: .init(linePrefix: "%")
    ]

    private let curly = LexerDefinition.BracketPair(open: "{", close: "}")
    private let paren = LexerDefinition.BracketPair(open: "(", close: ")")
    private let square = LexerDefinition.BracketPair(open: "[", close: "]")

    private func definition(for language: Language,
                            file: StaticString = #filePath,
                            line: UInt = #line) -> LexerDefinition? {
        guard let definition = LexerDefinitions.definition(for: language) else {
            XCTFail("\(language.rawValue) has no definition", file: file, line: line)
            return nil
        }
        return definition
    }

    private func offset(of needle: String,
                        in text: String,
                        from start: Int = 0) -> Int {
        let nsText = text as NSString
        let found = nsText.range(of: needle,
                                 options: [],
                                 range: NSRange(location: start,
                                                length: nsText.length - start))
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle) in fixture")
        return found.location
    }

    // MARK: - Comment metadata

    /// Every language that has comment syntax must declare it; `plain` has no
    /// definition, and JSON is the one highlighted language with no comment
    /// form.
    func testEveryLanguageExceptJSONHasNonEmptyCommentMetadata() {
        let highlighted = Set(Language.allCases.filter { $0 != .plain })
        XCTAssertEqual(Set(LexerDefinitions.dataDriven.map(\.language)),
                       Set(highlighted.map(\.rawValue)))

        for definition in LexerDefinitions.dataDriven {
            if definition.language == Language.json.rawValue {
                XCTAssertNil(definition.comments,
                             "JSON has no comment syntax; declaring one would be wrong")
                continue
            }

            guard let comments = definition.comments else {
                XCTFail("\(definition.language) has no comment metadata")
                continue
            }
            let hasLine = !(comments.linePrefix ?? "").isEmpty
            let hasBlock = !(comments.blockStart ?? "").isEmpty
                && !(comments.blockEnd ?? "").isEmpty
            XCTAssertTrue(hasLine || hasBlock,
                          "\(definition.language) declares no usable comment form")
            if hasBlock {
                XCTAssertNotEqual(comments.blockStart, comments.blockEnd,
                                  "\(definition.language) block delimiters are identical")
            }
        }
    }

    /// A block-comment start without an end (or the reverse) would make the
    /// fold model ignore the pair silently, so definitions must set both or
    /// neither.
    func testBlockCommentDelimitersAreAlwaysPaired() {
        for definition in LexerDefinitions.dataDriven {
            guard let comments = definition.comments else { continue }
            XCTAssertEqual(comments.blockStart == nil,
                           comments.blockEnd == nil,
                           "\(definition.language) has a half-declared block comment")
        }
    }

    func testCommentMetadataMatchesEachLanguage() {
        XCTAssertNil(LexerDefinition.json.comments)

        for (language, expected) in expectedComments {
            guard let definition = definition(for: language) else { continue }
            XCTAssertEqual(definition.comments, expected,
                           "\(language.rawValue) comment metadata is wrong")
        }
    }

    // MARK: - Bracket metadata

    func testBracketMetadataMatchesEachLanguage() {
        let allThree = [curly, paren, square]
        let expected: [Language: [LexerDefinition.BracketPair]] = [
            .json: [curly, square],
            .python: allThree,
            .javascript: allThree,
            .typescript: allThree,
            .html: [],
            .css: allThree,
            .markdown: [],
            .xml: [],
            .shell: allThree,
            .swift: allThree,
            .c: allThree,
            .cpp: allThree,
            .csharp: allThree,
            .java: allThree,
            .kotlin: allThree,
            .ruby: allThree,
            .go: allThree,
            .rust: allThree,
            .php: allThree,
            .sql: [paren],
            .yaml: [curly, square],
            .toml: [curly, square],
            .ini: [square],
            .lua: allThree,
            .r: allThree,
            .perl: allThree,
            .matlab: allThree,
            .haskell: allThree,
            .scala: allThree,
            .clojure: allThree,
            .dart: allThree,
            .ocaml: allThree,
            .erlang: allThree,
            .racket: allThree,
            .fsharp: allThree,
            .groovy: allThree,
            .nim: allThree,
            .zig: allThree,
            .batch: [],
            .cmake: [paren, curly],
            .makefile: [paren, curly],
            .powershell: allThree,
            .latex: [curly]
        ]

        XCTAssertEqual(Set(expected.keys), Set(Language.allCases.filter { $0 != .plain }))
        for (language, pairs) in expected {
            guard let definition = definition(for: language) else { continue }
            XCTAssertEqual(definition.brackets, pairs,
                           "\(language.rawValue) bracket metadata is wrong")
        }
    }

    func testDeclaredBracketPairsAreWellFormedAndUnique() {
        for definition in LexerDefinitions.dataDriven {
            var opens = Set<String>()
            for pair in definition.brackets {
                XCTAssertFalse(pair.open.isEmpty,
                               "\(definition.language) has an empty opening delimiter")
                XCTAssertFalse(pair.close.isEmpty,
                               "\(definition.language) has an empty closing delimiter")
                XCTAssertNotEqual(pair.open, pair.close,
                                  "\(definition.language) pair opens and closes with the same text")
                XCTAssertTrue(opens.insert(pair.open).inserted,
                              "\(definition.language) declares \(pair.open) twice")
            }
        }
    }

    /// HTML and XML cannot express tag-pair folding as a `BracketPair`: the
    /// closing delimiter repeats the tag name (`<div>` / `</div>`), and a bare
    /// `<`/`>` pair would fold unrelated text spans. The definitions leave
    /// `brackets` empty rather than forcing an inaccurate pair.
    func testHTMLAndXMLLeaveBracketsEmptyBecauseTagPairsAreNotBracketPairs() {
        for language in [Language.html, .xml] {
            guard let definition = definition(for: language) else { continue }
            XCTAssertTrue(definition.brackets.isEmpty,
                          "\(language.rawValue) must not fake tag pairs as brackets")
            XCTAssertEqual(definition.comments,
                           .init(blockStart: "<!--", blockEnd: "-->"))
        }
    }

    // MARK: - Markdown foldable ranges

    func testOnlyMarkdownDeclaresFoldableRangeRules() {
        XCTAssertEqual(LexerDefinition.markdown.foldableRangeRules.count, 1)

        for definition in LexerDefinitions.dataDriven
        where definition.language != Language.markdown.rawValue {
            XCTAssertTrue(definition.foldableRangeRules.isEmpty,
                          "\(definition.language) must not declare line-fold rules")
        }
    }

    func testMarkdownFoldableRangeRuleDescribesHeadingSections() throws {
        let rules = LexerDefinition.markdown.foldableRangeRules
        XCTAssertEqual(rules.count, 1)

        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.kind, .headingSection)

        // The fold rule must stay in lockstep with the highlighting rule.
        let headingPattern = try XCTUnwrap(
            LexerDefinition.markdown.rules.first { $0.name == "heading" }?.patterns.first
        )
        XCTAssertEqual(rule.startPattern, headingPattern)

        let regex = try NSRegularExpression(pattern: rule.startPattern, options: [])
        func firstMatch(in text: String) -> String? {
            let full = NSRange(location: 0, length: (text as NSString).length)
            guard let match = regex.firstMatch(in: text, options: [], range: full) else {
                return nil
            }
            return (text as NSString).substring(with: match.range)
        }

        XCTAssertEqual(firstMatch(in: "# Title\nbody"), "# Title")
        XCTAssertEqual(firstMatch(in: "\n### Section\n"), "### Section")
        for nonHeading in ["Title", "####### seven", "#nospace", "  ## indented"] {
            XCTAssertNil(firstMatch(in: nonHeading),
                         "\(nonHeading.debugDescription) must not open a heading fold")
        }
    }

    func testFoldableRangeRulesRoundTripAndDefaultToEmpty() throws {
        let decoded = try JSONDecoder().decode(
            LexerDefinition.self,
            from: JSONEncoder().encode(LexerDefinition.markdown)
        )
        XCTAssertEqual(decoded, LexerDefinition.markdown)
        XCTAssertEqual(decoded.foldableRangeRules, LexerDefinition.markdown.foldableRangeRules)

        let minimal = try LexerDefinition(json: #"{"language":"Minimal","rules":[]}"#)
        XCTAssertTrue(minimal.foldableRangeRules.isEmpty)
        XCTAssertNil(minimal.comments)
        XCTAssertTrue(minimal.brackets.isEmpty)
    }

    // MARK: - FoldModel integration

    /// The JSON definition declares `{}` and `[]`; a real document must fold
    /// through those pairs. Square brackets stay opt-in, and single-line pairs
    /// never fold by default.
    func testJSONDocumentFoldsThroughRealBraceMetadata() {
        let text = """
        {
          "items": [
            {
              "id": 1
            }
          ]
        }
        """
        guard let json = definition(for: .json) else { return }

        let defaultModel = FoldModel(text: text, definition: json)
        XCTAssertEqual(defaultModel.foldableRanges.map(\.kind), [.braces, .braces])

        let documentEnd = (text as NSString).range(of: "}", options: .backwards).location + 1
        XCTAssertEqual(defaultModel.foldableRanges[0].range,
                       NSRange(location: 0, length: documentEnd))
        XCTAssertEqual(defaultModel.foldableRanges[0].kind, .braces)

        let objectStart = offset(of: "{", in: text, from: offset(of: "[", in: text))
        let objectEnd = offset(of: "}", in: text, from: objectStart) + 1
        XCTAssertEqual(defaultModel.foldableRanges[1].range,
                       NSRange(location: objectStart,
                               length: objectEnd - objectStart))

        let arrayModel = FoldModel(
            text: text,
            definition: json,
            configuration: FoldConfiguration(foldsSquareBrackets: true)
        )
        XCTAssertEqual(arrayModel.foldableRanges.map(\.kind),
                       [.braces, .brackets, .braces])

        let arrayStart = offset(of: "[", in: text)
        let arrayEnd = offset(of: "]", in: text, from: arrayStart) + 1
        XCTAssertEqual(arrayModel.foldableRanges[1].range,
                       NSRange(location: arrayStart,
                               length: arrayEnd - arrayStart))

        // The array fold nests inside the document fold.
        XCTAssertTrue(NSLocationInRange(arrayStart,
                                        arrayModel.foldableRanges[0].range))
    }

    /// Swift's real comment metadata must drive folding: the block comment is
    /// its own fold, and braces inside it are not matched.
    func testSwiftBlockCommentMetadataDrivesCommentFolding() {
        let text = """
        func outer() {
            /* note
               } not a brace
            */
            work()
        }
        """
        guard let swift = definition(for: .swift) else { return }

        let model = FoldModel(text: text, definition: swift)
        XCTAssertEqual(model.foldableRanges.map(\.kind), [.braces, .blockComment])

        let commentStart = offset(of: "/*", in: text)
        let commentEnd = offset(of: "*/", in: text, from: commentStart) + 2
        XCTAssertEqual(model.foldableRanges[1].range,
                       NSRange(location: commentStart,
                               length: commentEnd - commentStart))

        let lastBrace = offset(of: "}", in: text, from: commentEnd)
        XCTAssertEqual(model.foldableRanges[0].upperBound, lastBrace + 1)
        XCTAssertTrue(NSLocationInRange(commentStart, model.foldableRanges[0].range))
    }

    /// Python declares `#` and no block comment, so a docstring-looking block
    /// must not be treated as a comment fold.
    func testPythonCommentMetadataDoesNotCreateBlockFolds() {
        guard let python = definition(for: .python) else { return }
        XCTAssertEqual(python.comments?.linePrefix, "#")
        XCTAssertNil(python.comments?.blockStart)
        XCTAssertNil(python.comments?.blockEnd)

        let text = """
        def f():
            \"\"\"doc
            # not a fold
            \"\"\"
            return 1
        """
        let model = FoldModel(text: text, definition: python)
        XCTAssertTrue(model.foldableRanges.allSatisfy { $0.kind != .blockComment })
    }

    /// HTML comment metadata is real even though tag pairs are not foldable.
    func testHTMLCommentMetadataProducesCommentFoldsOnly() {
        let text = """
        <body>
          <!--
            <div>commented out</div>
          -->
          <p>text</p>
        </body>
        """
        guard let html = definition(for: .html) else { return }

        let model = FoldModel(text: text, definition: html)
        XCTAssertEqual(model.foldableRanges.map(\.kind), [.blockComment])

        let start = offset(of: "<!--", in: text)
        let end = offset(of: "-->", in: text, from: start) + 3
        XCTAssertEqual(model.foldableRanges[0].range,
                       NSRange(location: start, length: end - start))
    }
}
