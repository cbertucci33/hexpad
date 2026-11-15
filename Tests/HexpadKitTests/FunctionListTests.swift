import XCTest
@testable import HexpadKit

final class FunctionListTests: XCTestCase {

    // MARK: - Definition metadata

    /// Every language that has a meaningful outline construct declares which
    /// highlighting rule supplies it. These are the kinds the slices ships:
    /// callables, Markdown sections, CSS selectors, and markup tags/attributes.
    private let expectedSymbolRules: [Language: [LexerDefinition.SymbolRule]] = [
        .swift: [.init(rule: "function", kind: .method)],
        .python: [.init(rule: "function", kind: .function)],
        .javascript: [.init(rule: "function", kind: .function)],
        .typescript: [.init(rule: "function", kind: .function)],
        .c: [.init(rule: "function", kind: .function)],
        .cpp: [.init(rule: "function", kind: .function)],
        .java: [.init(rule: "function", kind: .method)],
        .go: [.init(rule: "function", kind: .function)],
        .rust: [.init(rule: "function", kind: .function)],
        .php: [.init(rule: "function", kind: .function)],
        .ruby: [.init(rule: "function", kind: .method)],
        .csharp: [.init(rule: "function", kind: .method)],
        .kotlin: [.init(rule: "function", kind: .method)],
        .shell: [.init(rule: "function", kind: .function)],
        .markdown: [.init(rule: "heading", kind: .section)],
        .css: [.init(rule: "selector", kind: .selector)],
        .html: [
            .init(rule: "tag", kind: .tag),
            .init(rule: "attribute", kind: .attribute)
        ],
        .xml: [
            .init(rule: "tag", kind: .tag),
            .init(rule: "attribute", kind: .attribute)
        ]
    ]

    func testDefinitionsDeclareWhichRulesParticipateInTheOutline() {
        for (language, rules) in expectedSymbolRules {
            guard let definition = LexerDefinitions.definition(for: language) else {
                XCTFail("\(language.rawValue) has no definition")
                continue
            }
            XCTAssertEqual(definition.symbols, rules,
                           "\(language.rawValue) symbol metadata is wrong")
        }
    }

    func testLanguagesWithoutMeaningfulConstructsLeaveSymbolsNil() {
        for language in [Language.json, .sql, .yaml, .toml, .ini, .lua, .r] {
            XCTAssertNil(LexerDefinitions.definition(for: language)?.symbols,
                         "\(language.rawValue) should not produce an outline")
        }
    }

    func testSymbolMetadataRoundTripsThroughCodable() throws {
        let definition = LexerDefinition(
            language: "Sample",
            rules: [.init(name: "function", patterns: [#"\b[a-zA-Z_]\w*(?=\s*\()"#])],
            symbols: [.init(rule: "function", kind: .method)]
        )

        let decoded = try JSONDecoder().decode(
            LexerDefinition.self,
            from: JSONEncoder().encode(definition)
        )
        XCTAssertEqual(decoded.symbols, [.init(rule: "function", kind: .method)])

        let minimal = try LexerDefinition(json: #"{"language":"Minimal","rules":[]}"#)
        XCTAssertNil(minimal.symbols)
    }

    // MARK: - Fixtures

    private let swiftSource = """
    struct Greeter {
        var name = "World"
        let phrase = "func inString()"

        // func commentedOut() {}
        func greet(person: String) -> String {
            return "Hello, \\(person)"
        }

        func reset() {
            name = "World"
        }
    }
    """

    private let pythonSource = """
    class Greeter:
        def greet(self, name):
            return "hello " + name

        def reset(self):
            self.name = name

    # def commented_out():
    """

    private let markdownSource = """
    # Title

    Intro text.

    ## Getting Started ##

    ### Details

    <!-- # Hidden heading -->
    """

    private let cssSource = """
    /* .commented { color: red; } */
    .card {
        color: red;
    }

    #main {
        padding: 1em;
    }
    """

    private let htmlSource = """
    <div class="box">
      <span id="x">Hi</span>
    </div>
    """

    private let rubySource = """
    def greet(name)
      puts name
    end

    def reset; greet("x"); end
    """

    private let javascriptSource = """
    // function hidden() {}
    /* function alsoHidden() {} */
    const s = "function inString()";
    function visible() {
        return "done";
    }
    """

    // MARK: - Swift

    func testSwiftMethodsAreExtractedAndPropertiesAreIgnored() {
        let model = FunctionListModel(text: swiftSource, language: .swift)

        XCTAssertEqual(model.symbols.map(\.name), ["greet", "reset"])
        XCTAssertEqual(model.symbols.map(\.kind), [.method, .method])
        XCTAssertEqual(model.symbols.map(\.line), [6, 10])

        // The range is the identifier, not the whole declaration.
        let swifts = swiftSource as NSString
        XCTAssertEqual(model.symbols[0].range, swifts.range(of: "greet"))
        XCTAssertEqual(model.symbols[1].range, swifts.range(of: "reset"))

        // Properties and comment/string contents must not become symbols.
        XCTAssertFalse(model.symbols.contains { $0.name == "name" })
        XCTAssertFalse(model.symbols.contains { $0.name == "phrase" })
        XCTAssertFalse(model.symbols.contains { $0.name == "commentedOut" })
        XCTAssertFalse(model.symbols.contains { $0.name == "inString" })
    }

    // MARK: - Python

    func testPythonDefsInsideAClassProduceFunctionSymbols() {
        let model = FunctionListModel(text: pythonSource, language: .python)

        XCTAssertEqual(model.symbols.map(\.name), ["greet", "reset"])
        XCTAssertEqual(model.symbols.map(\.kind), [.function, .function])
        XCTAssertEqual(model.symbols.map(\.line), [2, 5])
        XCTAssertFalse(model.symbols.contains { $0.name == "commented_out" })
    }

    // MARK: - Markdown

    func testMarkdownHeadingsProduceSections() {
        let model = FunctionListModel(text: markdownSource, language: .markdown)

        XCTAssertEqual(model.symbols.map(\.name), ["Title", "Getting Started", "Details"])
        XCTAssertEqual(model.symbols.map(\.kind), [.section, .section, .section])
        XCTAssertEqual(model.symbols.map(\.line), [1, 5, 7])

        // Closing ATX hashes are punctuation, not part of the name.
        XCTAssertFalse(model.symbols.contains { $0.name.hasSuffix("#") })
        XCTAssertFalse(model.symbols.contains { $0.name == "Hidden heading" })
    }

    // MARK: - CSS

    func testCSSSelectorsProduceSelectorSymbols() {
        let model = FunctionListModel(text: cssSource, language: .css)

        XCTAssertEqual(model.symbols.map(\.name), [".card", "#main"])
        XCTAssertEqual(model.symbols.map(\.kind), [.selector, .selector])
        XCTAssertEqual(model.symbols.map(\.line), [2, 6])
        XCTAssertFalse(model.symbols.contains { $0.name == ".commented" })
    }

    // MARK: - Markup

    func testHTMLTagsAndAttributesProduceOutlineEntries() {
        let model = FunctionListModel(text: htmlSource, language: .html)

        XCTAssertEqual(model.symbols.map(\.name), ["div", "class", "span", "id"])
        XCTAssertEqual(model.symbols.map(\.kind),
                       [.tag, .attribute, .tag, .attribute])
        XCTAssertEqual(model.symbols.map(\.line), [1, 1, 2, 2])
    }

    // MARK: - Same-line dedupe

    func testDuplicateMatchesOnOneLineCollapseToOneCallable() {
        let model = FunctionListModel(text: rubySource, language: .ruby)

        // Ruby's function rule has two patterns ("def name" and "name("), so
        // "def greet(name)" matches twice on line 1. The call to greet() after
        // the declaration on line 5 must not add a second entry either.
        XCTAssertEqual(model.symbols.map(\.name), ["greet", "reset"])
        XCTAssertEqual(model.symbols.map(\.line), [1, 5])
        XCTAssertEqual(Set(model.symbols.map(\.line)).count, model.symbols.count)
    }

    // MARK: - Comment/string exclusion

    func testSymbolsInsideCommentsAndStringsAreSkipped() {
        let model = FunctionListModel(text: javascriptSource, language: .javascript)

        XCTAssertEqual(model.symbols.map(\.name), ["visible"])
        XCTAssertEqual(model.symbols.first?.line, 4)
        XCTAssertEqual(model.symbols.first?.kind, .function)
        for hidden in ["hidden", "alsoHidden", "inString"] {
            XCTAssertFalse(model.symbols.contains { $0.name == hidden },
                           "\(hidden) must not appear in the outline")
        }
    }

    // MARK: - Empty and unsupported documents

    func testEmptyDocumentProducesNoSymbols() {
        XCTAssertTrue(FunctionListModel(text: "", language: .swift).isEmpty)
        XCTAssertTrue(FunctionListModel(text: "\n\n", language: .swift).symbols.isEmpty)
    }

    func testLanguageWithoutSymbolMetadataReturnsEmptyOutline() {
        let model = FunctionListModel(text: #"{"call": true}"#, language: .json)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(LexerDefinition.json.symbols)

        XCTAssertTrue(FunctionListModel(text: "plain text", language: .plain).isEmpty)
    }

    func testUnknownSymbolRuleIsIgnored() {
        let definition = LexerDefinition(
            language: "Sample",
            rules: [.init(name: "keyword", patterns: ["let"])],
            symbols: [.init(rule: "missing", kind: .function)]
        )
        XCTAssertTrue(FunctionListModel(text: "let value = 1\n", definition: definition).isEmpty)
    }

    // MARK: - Ordering and range contract

    func testSymbolsAreSortedByDocumentPositionAndRangesMatchTheirNames() {
        let model = FunctionListModel(text: htmlSource, language: .html)
        let locations = model.symbols.map(\.range.location)
        XCTAssertEqual(locations, locations.sorted())

        let nsText = htmlSource as NSString
        for symbol in model.symbols {
            XCTAssertEqual(nsText.substring(with: symbol.range), symbol.name)
        }
    }
}
