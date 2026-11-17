import XCTest
@testable import HexpadKit

/// Coverage for the additional grammars added after the S-P8e breadth slice.
///
/// Each language gets one fixture that must tokenize into the four core token
/// kinds through the production path. The comment metadata and file-extension
/// mappings are asserted here so the new definitions cannot drift from the
/// editing structure the rest of the app reads.
final class AdditionalLanguageTests: XCTestCase {

    /// Tokenizes a fixture and asserts the four core token kinds plus the
    /// language-specific keyword and comment spelling.
    private func assertTokenizes(_ source: String,
                                 language: Language,
                                 keyword: String,
                                 commentPrefix: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let definition = try XCTUnwrap(LexerDefinitions.definition(for: language),
                                       "\(language.rawValue) has no definition",
                                       file: file, line: line)

        // The loader silently drops uncompilable patterns, so compiled count
        // must equal the declared pattern count.
        let declaredPatterns = definition.rules.reduce(0) { $0 + $1.patterns.count }
        XCTAssertEqual(LexerDefinitionLoader.compiledRules(from: definition).count,
                       declaredPatterns,
                       "\(language.rawValue) has a pattern that does not compile",
                       file: file, line: line)

        let tokens = SyntaxTokenizer.tokenize(source, language: language)

        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == keyword },
                      "\(language.rawValue) fixture produced no \(keyword) keyword",
                      file: file, line: line)
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text.hasPrefix(commentPrefix) },
                      "\(language.rawValue) fixture produced no \(commentPrefix) comment",
                      file: file, line: line)
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text.contains("hi") },
                      "\(language.rawValue) fixture produced no string token",
                      file: file, line: line)
        XCTAssertTrue(tokens.contains { $0.type == .number && $0.text == "42" },
                      "\(language.rawValue) fixture produced no number token",
                      file: file, line: line)

        // Whole-document coverage: no text is dropped or overlapped.
        XCTAssertEqual(tokens.reduce(0) { $0 + $1.range.length },
                       (source as NSString).length,
                       "\(language.rawValue) tokens do not cover the fixture",
                       file: file, line: line)
    }

    func testPerlFixtureTokenizes() throws {
        try assertTokenizes("""
        #!/usr/bin/perl
        # note
        use strict;
        my $name = "hi";
        my $count = 42;
        sub greet { return $name; }
        """,
        language: .perl,
        keyword: "my",
        commentPrefix: "#")
    }

    func testMatlabFixtureTokenizes() throws {
        try assertTokenizes("""
        % note
        function result = greet(name)
            count = 42;
            result = 'hi';
            if count > 0
                result = "ok";
            end
        end
        """,
        language: .matlab,
        keyword: "function",
        commentPrefix: "%")
    }

    func testHaskellFixtureTokenizes() throws {
        try assertTokenizes("""
        -- note
        greet :: String -> Int
        greet name = let count = 42 in count
        message = "hi"
        """,
        language: .haskell,
        keyword: "let",
        commentPrefix: "--")
    }

    func testScalaFixtureTokenizes() throws {
        try assertTokenizes("""
        // note
        object Greeter {
            def greet(name: String): String = {
                val count = 42
                "hi"
            }
        }
        """,
        language: .scala,
        keyword: "val",
        commentPrefix: "//")
    }

    func testClojureFixtureTokenizes() throws {
        try assertTokenizes("""
        ; note
        (defn greet [name]
          (let [count 42]
            (str "hi" name)))
        """,
        language: .clojure,
        keyword: "defn",
        commentPrefix: ";")
    }

    func testDartFixtureTokenizes() throws {
        try assertTokenizes("""
        // note
        class Greeter {
          final String name = "hi";
          int count = 42;
          final raw = r'C:\\temp';
        }
        """,
        language: .dart,
        keyword: "class",
        commentPrefix: "//")
    }

    func testOCamlFixtureTokenizes() throws {
        try assertTokenizes("""
        (* note *)
        let greet name =
          let count = 42 in
          "hi"
        """,
        language: .ocaml,
        keyword: "let",
        commentPrefix: "(*")
    }

    func testErlangFixtureTokenizes() throws {
        try assertTokenizes("""
        % note
        greet(Name) ->
            Count = 42,
            case Name of
                _ -> "hi"
            end.
        """,
        language: .erlang,
        keyword: "case",
        commentPrefix: "%")
    }

    func testNewFileExtensionsMapToLanguages() {
        let expected: [(String, Language)] = [
            ("script.pl", .perl), ("Module.pm", .perl),
            ("plot.m", .matlab), ("solver.matlab", .matlab),
            ("Main.hs", .haskell),
            ("Main.scala", .scala),
            ("core.clj", .clojure), ("ui.cljs", .clojure), ("shared.cljc", .clojure),
            ("main.dart", .dart),
            ("main.ml", .ocaml), ("main.mli", .ocaml),
            ("server.erl", .erlang), ("server.hrl", .erlang)
        ]

        for (name, language) in expected {
            XCTAssertEqual(Language.fromFileName(name), language,
                           "\(name) should map to \(language.rawValue)")
        }
    }
}
