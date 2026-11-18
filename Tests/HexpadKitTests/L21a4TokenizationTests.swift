import XCTest
@testable import HexpadKit

/// Tokenization coverage for the L21a-4 batch: Batch, CMake, Makefile,
/// PowerShell, and LaTeX.
///
/// Each fixture follows `AdditionalLanguageTests`: it goes through the
/// production tokenizer, must declare every pattern the loader compiles, and
/// must cover the whole document without dropping text. LaTeX is the one
/// exception to the four-core-kinds rule because it has no string construct
/// worth a rule; the test says so explicitly instead of inventing one.
final class L21a4TokenizationTests: XCTestCase {

    private func assertTokenizes(_ source: String,
                                 language: Language,
                                 keyword: String,
                                 commentPrefix: String,
                                 expectsString: Bool = true,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let definition = try XCTUnwrap(LexerDefinitions.definition(for: language),
                                       "\(language.rawValue) has no definition",
                                       file: file, line: line)

        // The loader drops uncompilable patterns silently.
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
        XCTAssertTrue(tokens.contains { $0.type == .number && $0.text == "42" },
                      "\(language.rawValue) fixture produced no number token",
                      file: file, line: line)
        if expectsString {
            XCTAssertTrue(tokens.contains { $0.type == .string && $0.text.contains("hi") },
                          "\(language.rawValue) fixture produced no string token",
                          file: file, line: line)
        } else {
            XCTAssertFalse(definition.rules.contains { $0.name == "string" },
                           "\(language.rawValue) must not invent a string rule",
                           file: file, line: line)
        }

        XCTAssertEqual(tokens.reduce(0) { $0 + $1.range.length },
                       (source as NSString).length,
                       "\(language.rawValue) tokens do not cover the fixture",
                       file: file, line: line)
    }

    func testBatchFixtureTokenizes() throws {
        try assertTokenizes("""
        @echo off
        rem note
        :: also a note
        set NAME="hi"
        set COUNT=42
        if "%NAME%"=="hi" call :greet
        :greet
        echo done
        exit /b 0
        """,
        language: .batch,
        keyword: "set",
        commentPrefix: "rem")
    }

    func testCMakeFixtureTokenizes() throws {
        try assertTokenizes("""
        # note
        cmake_minimum_required(VERSION 3.20)
        project(Demo)
        set(NAME "hi")
        if(NAME)
            set(COUNT 42)
        endif()
        """,
        language: .cmake,
        keyword: "set",
        commentPrefix: "#")
    }

    func testMakefileFixtureTokenizes() throws {
        try assertTokenizes("""
        # note
        NAME := "hi"
        COUNT := 42
        ifeq ($(NAME), "hi")
            echo $(NAME)
        endif
        """,
        language: .makefile,
        keyword: "ifeq",
        commentPrefix: "#")
    }

    func testPowerShellFixtureTokenizes() throws {
        try assertTokenizes("""
        # note
        <#
          block note
        #>
        param([string]$Name)
        $count = 42
        function Get-Greeting {
            Write-Host "hi $Name"
        }
        if ($count -gt 0) {
            Write-Host "ready"
        }
        """,
        language: .powershell,
        keyword: "param",
        commentPrefix: "#")
    }

    func testLaTeXFixtureTokenizes() throws {
        try assertTokenizes("""
        % note
        \\documentclass{article}
        \\begin{document}
        \\section{Intro}
        There are 42 apples and a literal \\% sign.
        \\textbf{Hello}
        \\end{document}
        """,
        language: .latex,
        keyword: "\\section",
        commentPrefix: "%",
        expectsString: false)
    }

    func testNewFileExtensionsMapToLanguages() {
        let expected: [(String, Language)] = [
            ("run.bat", .batch), ("run.cmd", .batch),
            ("CMakeLists.txt", .cmake), ("build.cmake", .cmake),
            ("Makefile", .makefile), ("GNUmakefile", .makefile), ("rules.mk", .makefile),
            ("profile.ps1", .powershell), ("Module.psm1", .powershell),
            ("main.tex", .latex), ("paper.latex", .latex)
        ]

        for (name, language) in expected {
            XCTAssertEqual(Language.fromFileName(name), language,
                           "\(name) should map to \(language.rawValue)")
        }

        // Only the canonical Make filenames are case-sensitive.
        XCTAssertEqual(Language.fromFileName("makefile"), .plain)
        XCTAssertEqual(Language.fromFileName("gnumakefile"), .plain)
    }

    func testPowerShellBlockCommentIsOneToken() {
        let source = """
        <#
          block note
        #>
        Write-Host "hi"
        """
        let tokens = SyntaxTokenizer.tokenize(source, language: .powershell)
        let block = tokens.first { $0.type == .comment }
        XCTAssertEqual(block?.text, "<#\n  block note\n#>")
    }

    func testBatchDoubleColonLineIsAComment() {
        let tokens = SyntaxTokenizer.tokenize(":: note\necho hi", language: .batch)
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text == ":: note" })
    }

    func testLaTeXEscapedPercentIsNotAComment() {
        let tokens = SyntaxTokenizer.tokenize("\\% literal\n% real", language: .latex)
        XCTAssertEqual(tokens.filter { $0.type == .comment }.map(\.text), ["% real"])
    }
}
