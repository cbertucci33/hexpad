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

    func testJSONResolvesThroughDefinitionAndOthersThroughSwiftTables() {
        XCTAssertEqual(LexerDefinitions.definition(for: .json), .json)
        XCTAssertNil(LexerDefinitions.definition(for: .python))
        XCTAssertNil(SyntaxTokenizer.languageRules[.json],
                     "JSON must use the data-driven definition, not a stale dictionary")
        XCTAssertNotNil(SyntaxTokenizer.languageRules[.python],
                        "unmigrated languages keep their Swift dictionaries")
    }
}
