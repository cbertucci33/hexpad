import XCTest
@testable import HexpadKit

/// Breadth coverage for the languages added in slice S-P8e.
///
/// Every new definition must decode, declare usable comment and bracket
/// metadata, resolve through `Language.fromFileName`, and tokenize a small
/// fixture into keyword/comment/string/number tokens through the production
/// path. The existing definitions keep their own coverage in
/// `LexerDefinitionTests` and `LexerDefinitionMetadataTests`.
final class LanguageBreadthTests: XCTestCase {

    /// The languages this slice adds, with one representative source sample
    /// per language. Each sample contains a keyword, a comment, a string, and a
    /// number so one tokenize pass exercises all four core rule kinds.
    private let fixtures: [(language: Language, source: String)] = [
        (.c, """
        // note
        int main(void) {
            int count = 42;
            return count;
        }
        char *s = "hi";
        """),
        (.cpp, """
        // note
        class Greeter {
        public:
            int count = 42;
            std::string name = "hi";
        };
        """),
        (.csharp, """
        // note
        class Greeter {
            string name = "hi";
            int count = 42;
        }
        """),
        (.java, """
        // note
        class Greeter {
            String name = "hi";
            int count = 42;
        }
        """),
        (.kotlin, """
        // note
        fun greet(name: String): String {
            val count = 42
            return "hi"
        }
        """),
        (.ruby, """
        # note
        def greet(name)
          count = 42
          "hi"
        end
        """),
        (.go, """
        // note
        func greet(name string) string {
            count := 42
            return "hi"
        }
        """),
        (.rust, """
        // note
        fn greet(name: &str) -> String {
            let count = 42;
            "hi".to_string()
        }
        """),
        (.php, """
        <?php
        // note
        function greet(string $name): string {
            $count = 42;
            return "hi";
        }
        """),
        (.sql, """
        -- note
        SELECT name FROM users WHERE name = 'hi' AND id = 42;
        """),
        (.yaml, """
        # note
        name: "hi"
        count: 42
        enabled: true
        """),
        (.toml, """
        # note
        name = "hi"
        count = 42
        enabled = true
        """),
        (.ini, """
        ; note
        name = "hi"
        count = 42
        enabled = true
        """),
        (.lua, """
        -- note
        local name = "hi"
        local count = 42
        function greet() return name end
        """),
        (.r, """
        # note
        greet <- function(name) {
          if (TRUE) {
            count <- 42
            "hi"
          }
        }
        """)
    ]

    /// Config formats have no function construct; every other new language
    /// does.
    private let languagesWithoutFunctions: Set<Language> = [.yaml, .toml, .ini]

    // MARK: - Language enum stability

    func testExistingLanguageCasesRemainStable() {
        let original = ["Plain Text", "JSON", "Python", "JavaScript", "TypeScript",
                        "HTML", "CSS", "Markdown", "XML", "Shell", "Swift"]
        XCTAssertEqual(Array(Language.allCases.prefix(original.count)).map(\.rawValue),
                       original,
                       "existing cases must keep their order and raw values")
        XCTAssertEqual(Language.allCases.count, 26,
                       "11 built-ins plus the 15 slice S-P8e languages")
    }

    // MARK: - Decoding and metadata

    func testEveryNewLanguageDecodesWithMetadata() throws {
        for (language, _) in fixtures {
            let definition = try XCTUnwrap(LexerDefinitions.definition(for: language),
                                           "\(language.rawValue) has no definition")
            XCTAssertEqual(definition.language, language.rawValue)
            XCTAssertFalse(definition.rules.isEmpty,
                           "\(language.rawValue) has an empty rule table")

            let comments = try XCTUnwrap(definition.comments,
                                         "\(language.rawValue) has no comment metadata")
            let hasLine = !(comments.linePrefix ?? "").isEmpty
            let hasBlock = !(comments.blockStart ?? "").isEmpty
                && !(comments.blockEnd ?? "").isEmpty
            XCTAssertTrue(hasLine || hasBlock,
                          "\(language.rawValue) declares no usable comment form")

            XCTAssertFalse(definition.brackets.isEmpty,
                           "\(language.rawValue) has no bracket metadata")
            for pair in definition.brackets {
                XCTAssertFalse(pair.open.isEmpty)
                XCTAssertFalse(pair.close.isEmpty)
                XCTAssertNotEqual(pair.open, pair.close)
            }

            let ruleNames = Set(definition.rules.map(\.name))
            for required in ["keyword", "string", "comment", "number", "type"] {
                XCTAssertTrue(ruleNames.contains(required),
                              "\(language.rawValue) is missing the \(required) rule")
            }
            if !languagesWithoutFunctions.contains(language) {
                XCTAssertTrue(ruleNames.contains("function"),
                              "\(language.rawValue) is missing the function rule")
            }

            // The loader skips unknown rule names and invalid regexes silently,
            // so compiled count must equal the declared pattern count.
            let declaredPatterns = definition.rules.reduce(0) { $0 + $1.patterns.count }
            XCTAssertEqual(LexerDefinitionLoader.compiledRules(from: definition).count,
                           declaredPatterns,
                           "\(language.rawValue) has a pattern that does not compile")
        }
    }

    func testEveryNewDefinitionRoundTripsThroughCodable() throws {
        for (language, _) in fixtures {
            let definition = try XCTUnwrap(LexerDefinitions.definition(for: language))
            let decoded = try JSONDecoder().decode(
                LexerDefinition.self,
                from: JSONEncoder().encode(definition)
            )
            XCTAssertEqual(decoded, definition,
                           "\(language.rawValue) did not round-trip")
        }
    }

    // MARK: - File name mapping

    func testFromFileNameMapsNewExtensions() {
        let expected: [(String, Language)] = [
            ("main.c", .c), ("header.h", .c),
            ("main.cpp", .cpp), ("unit.cc", .cpp),
            ("header.hpp", .cpp), ("legacy.cxx", .cpp),
            ("Program.cs", .csharp),
            ("Main.java", .java),
            ("Main.kt", .kotlin), ("build.kts", .kotlin),
            ("script.rb", .ruby),
            ("main.go", .go),
            ("lib.rs", .rust),
            ("index.php", .php),
            ("query.sql", .sql),
            ("config.yaml", .yaml), ("config.yml", .yaml),
            ("config.toml", .toml),
            ("settings.ini", .ini), ("settings.cfg", .ini),
            ("app.conf", .ini),
            ("init.lua", .lua),
            ("analysis.r", .r), ("ANALYSIS.R", .r)
        ]

        for (name, language) in expected {
            XCTAssertEqual(Language.fromFileName(name), language,
                           "\(name) should map to \(language.rawValue)")
        }

        XCTAssertEqual(Language.fromFileName("notes.txt"), .plain)
        XCTAssertEqual(Language.fromFileName("archive.unknown"), .plain)
    }

    // MARK: - Tokenization smoke checks

    func testEveryNewLanguageTokenizesKeywordCommentStringAndNumber() {
        for (language, source) in fixtures {
            let tokens = SyntaxTokenizer.tokenize(source, language: language)
            let types = Set(tokens.map(\.type))
            for expected in [TokenType.keyword, .comment, .string, .number] {
                XCTAssertTrue(types.contains(expected),
                              "\(language.rawValue) fixture produced no \(expected.rawValue) token")
            }

            // Whole-document coverage: no text is dropped or overlapped.
            let length = (source as NSString).length
            XCTAssertEqual(tokens.reduce(0) { $0 + $1.range.length }, length,
                           "\(language.rawValue) tokens do not cover the fixture")
        }
    }
}
