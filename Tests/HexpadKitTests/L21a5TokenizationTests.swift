import XCTest
@testable import HexpadKit

/// Tokenization coverage for the L21a-5 batch: Objective-C, Pascal, Ada, Diff,
/// and Properties.
///
/// Each fixture follows `L21a4TokenizationTests`: it goes through the
/// production tokenizer, must declare every pattern the loader compiles, and
/// must cover the whole document without dropping text. Diff and Properties
/// deliberately have smaller rule sets than the language batches before them,
/// so their tests pin exactly which token types they do and do not produce.
final class L21a5TokenizationTests: XCTestCase {

    /// The loader drops uncompilable patterns silently, so pin the compiled
    /// count against the declared count for every new grammar.
    @discardableResult
    private func definitionWithCompilablePatterns(
        _ language: Language,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LexerDefinition {
        let definition = try XCTUnwrap(LexerDefinitions.definition(for: language),
                                       "\(language.rawValue) has no definition",
                                       file: file, line: line)
        XCTAssertEqual(definition.language, language.rawValue, file: file, line: line)
        let declared = definition.rules.reduce(0) { $0 + $1.patterns.count }
        XCTAssertEqual(LexerDefinitionLoader.compiledRules(from: definition).count,
                       declared,
                       "\(language.rawValue) has a pattern that does not compile",
                       file: file, line: line)
        return definition
    }

    private func assertCovers(_ source: String,
                              language: Language,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let tokens = SyntaxTokenizer.tokenize(source, language: language)
        XCTAssertEqual(tokens.reduce(0) { $0 + $1.range.length },
                       (source as NSString).length,
                       "\(language.rawValue) tokens do not cover the fixture",
                       file: file, line: line)
    }

    // MARK: - Fixtures

    func testObjectiveCFixtureTokenizes() throws {
        let source = """
        #import <Foundation/Foundation.h>
        #include <stdio.h>

        @interface Greeter : NSObject
        @property (nonatomic, copy) NSString *name;
        @end

        @implementation Greeter
        - (void)sayHello {
            // greet
            NSString *message = @"hi, 42";
            NSInteger count = 42;
            printf("%s", "ok");
            NSLog(@"%@", message);
        }
        @end
        """
        let definition = try definitionWithCompilablePatterns(.objectivec)
        let tokens = SyntaxTokenizer.tokenize(source, language: .objectivec)

        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "#import <Foundation/Foundation.h>" },
                      "Objective-C preprocessor import should be a keyword")
        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "@interface" })
        XCTAssertTrue(tokens.contains { $0.type == .type && $0.text == "NSObject" })
        XCTAssertTrue(tokens.contains { $0.type == .type && $0.text == "NSString" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "// greet" })
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text == "@\"hi, 42\"" })
        XCTAssertTrue(tokens.contains { $0.type == .number && $0.text == "42" })

        let opens = definition.brackets.map(\.open)
        XCTAssertEqual(opens, ["(", "[", "{", "<"])
        assertCovers(source, language: .objectivec)
    }

    func testPascalFixtureTokenizes() throws {
        let source = """
        program Hello;
        { block note }
        (* another note *)
        // line note
        procedure Greet(Name: string);
        var
          Count: Integer;
        begin
          Count := 42;
          if Count > 0 then
            Writeln('hi');
        end.
        """
        try definitionWithCompilablePatterns(.pascal)
        let tokens = SyntaxTokenizer.tokenize(source, language: .pascal)

        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "procedure" })
        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "begin" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "{ block note }" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "(* another note *)" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "// line note" })
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text == "'hi'" })
        XCTAssertTrue(tokens.contains { $0.type == .number && $0.text == "42" })
        assertCovers(source, language: .pascal)
    }

    func testAdaFixtureTokenizes() throws {
        let source = """
        with Ada.Text_IO;
        use Ada.Text_IO;
        -- note
        procedure Hello is
           Count : Integer := 42;
        begin
           if Count > 0 then
              Put_Line("hi");
           elsif Count < 0 then
              Put_Line("neg");
           end if;
        end Hello;
        """
        try definitionWithCompilablePatterns(.ada)
        let tokens = SyntaxTokenizer.tokenize(source, language: .ada)

        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "procedure" })
        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "elsif" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "-- note" })
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text == "\"hi\"" })
        XCTAssertTrue(tokens.contains { $0.type == .number && $0.text == "42" })
        assertCovers(source, language: .ada)
    }

    func testDiffFixtureTokenizes() throws {
        let source = """
        Index: Sample.txt
        ===================================================================
        --- Sample.txt
        +++ Sample.txt
        @@ -1,3 +1,4 @@
         context line
        -removed line 42
        +added line "hi"
        +second addition
        """
        let definition = try definitionWithCompilablePatterns(.diff)
        let tokens = SyntaxTokenizer.tokenize(source, language: .diff)

        // Additions are `string`, removals are `comment`, headers are `keyword`.
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text == "+added line \"hi\"" })
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text == "+second addition" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "-removed line 42" })
        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text.contains("@@") })
        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "Index: Sample.txt" })
        XCTAssertFalse(tokens.contains { $0.type == .number },
                       "Diff has no number rule; 42 belongs to the removal token")
        XCTAssertNil(definition.comments, "Diff has no comment metadata")
        XCTAssertTrue(definition.brackets.isEmpty, "Diff has no brackets")
        XCTAssertFalse(definition.rules.contains { $0.name == "number" })
        assertCovers(source, language: .diff)
    }

    func testPropertiesFixtureTokenizes() throws {
        let source = """
        # config note
        ! alternate note
        app.name=Demo
        max.count = 42
        url=https://example.com?a=b
        """
        let definition = try definitionWithCompilablePatterns(.properties)
        let tokens = SyntaxTokenizer.tokenize(source, language: .properties)

        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "# config note" })
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == "! alternate note" })
        for key in ["app.name", "max.count", "url"] {
            XCTAssertTrue(tokens.contains { $0.type == .variable && $0.text == key },
                          "Properties key \(key) should be a variable token")
        }
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text.contains("Demo") })
        XCTAssertTrue(tokens.contains { $0.type == .string && $0.text.contains("42") })
        XCTAssertFalse(definition.rules.contains { $0.name == "number" })
        XCTAssertTrue(definition.brackets.isEmpty, "Properties has no brackets")
        XCTAssertEqual(definition.comments?.linePrefix, "#")
        assertCovers(source, language: .properties)
    }

    // MARK: - Filename mappings

    func testNewFileExtensionsMapToLanguages() {
        let expected: [(String, Language)] = [
            ("Class.mm", .objectivec),
            ("unit.pas", .pascal), ("app.dpr", .pascal), ("prog.lpr", .pascal),
            ("body.adb", .ada), ("spec.ads", .ada),
            ("changes.diff", .diff), ("fix.patch", .diff),
            ("app.properties", .properties)
        ]
        for (name, language) in expected {
            XCTAssertEqual(Language.fromFileName(name), language,
                           "\(name) should map to \(language.rawValue)")
        }
    }

    /// `.m` is shared by MATLAB and Objective-C. MATLAB appears first in the
    /// `fromFileName` chain and keeps it; Objective-C gets only `.mm`. Pin the
    /// behavior as found rather than changing the pre-existing mapping.
    func testObjectiveCMDotMDisambiguationPinnedToMATLAB() {
        XCTAssertEqual(Language.fromFileName("Class.m"), .matlab)
        XCTAssertEqual(Language.fromFileName("CLASS.M"), .matlab)
        XCTAssertEqual(Language.fromFileName("script.matlab"), .matlab)
        XCTAssertEqual(Language.fromFileName("Class.mm"), .objectivec)
        XCTAssertEqual(Language.fromFileName("CLASS.MM"), .objectivec)
        XCTAssertNotEqual(Language.fromFileName("Class.m"), .objectivec)
    }
}
