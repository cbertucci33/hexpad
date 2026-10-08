import XCTest
@testable import HexpadKit

final class SyntaxTokenizerTests: XCTestCase {
    func testPlainLanguage() {
        let tokens = SyntaxTokenizer.tokenize("hello world", language: .plain)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].type, .plain)
    }
    
    func testPythonKeywords() {
        let tokens = SyntaxTokenizer.tokenize("def hello(): pass", language: .python)
        let types = tokens.map { $0.type }
        XCTAssertTrue(types.contains(.keyword))
        XCTAssertTrue(types.contains(.function))
    }
    
    func testJSONKeywords() {
        let tokens = SyntaxTokenizer.tokenize("{\"key\": true}", language: .json)
        let types = tokens.map { $0.type }
        XCTAssertTrue(types.contains(.keyword))
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.contains(.punctuation))
    }
    
    func testCommentDetection() {
        let tokens = SyntaxTokenizer.tokenize("// comment", language: .javascript)
        let types = tokens.map { $0.type }
        XCTAssertTrue(types.contains(.comment))
    }
    
    func testStringDetection() {
        let tokens = SyntaxTokenizer.tokenize("'hello world'", language: .python)
        let types = tokens.map { $0.type }
        XCTAssertTrue(types.contains(.string))
    }
    
    func testNumberDetection() {
        let tokens = SyntaxTokenizer.tokenize("42", language: .python)
        let types = tokens.map { $0.type }
        XCTAssertTrue(types.contains(.number))
    }
    
    func testLanguageFromFileExtension() {
        XCTAssertEqual(Language.fromFileName("test.json"), .json)
        XCTAssertEqual(Language.fromFileName("test.py"), .python)
        XCTAssertEqual(Language.fromFileName("test.js"), .javascript)
        XCTAssertEqual(Language.fromFileName("test.ts"), .typescript)
        XCTAssertEqual(Language.fromFileName("test.html"), .html)
        XCTAssertEqual(Language.fromFileName("test.css"), .css)
        XCTAssertEqual(Language.fromFileName("test.md"), .markdown)
        XCTAssertEqual(Language.fromFileName("test.xml"), .xml)
        XCTAssertEqual(Language.fromFileName("test.sh"), .shell)
        XCTAssertEqual(Language.fromFileName("test.txt"), .plain)
    }
    
    func testThemeAvailability() {
        for theme in HexpadTheme.allCases {
            let t = theme.theme
            XCTAssertFalse(t.name.isEmpty)
            XCTAssertNotNil(t.background)
            XCTAssertNotNil(t.foreground)
        }
    }
    
    func testAllLanguagesHaveRules() {
        for language in Language.allCases {
            let tokens = SyntaxTokenizer.tokenize("test", language: language)
            XCTAssertFalse(tokens.isEmpty)
        }
    }
}
