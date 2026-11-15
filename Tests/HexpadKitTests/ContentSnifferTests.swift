import XCTest
@testable import HexpadKit

final class ContentSnifferTests: XCTestCase {
    func testShebangPython() {
        let data = Data("#!/usr/bin/env python3\nprint('hello')\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .python)
    }
    
    func testShebangBash() {
        let data = Data("#!/bin/bash\necho hello\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .shell)
    }
    
    func testXMLHeader() {
        let data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root></root>\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .xml)
    }
    
    func testHTMLDoctype() {
        let data = Data("<!DOCTYPE html>\n<html>\n<head><title>Test</title></head>\n</html>\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .html)
    }
    
    func testJSONBraces() {
        let data = Data("{\n  \"name\": \"test\",\n  \"value\": 42\n}\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .json)
    }
    
    func testPlainTextReturnsNil() {
        let data = Data("Just a plain text file with no special markers at all.\n".utf8)
        XCTAssertNil(ContentSniffer.sniffLanguage(data))
    }
    
    func testPythonDensity() {
        let data = Data("import os\nimport sys\n\ndef main():\n    print('hi')\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .python)
    }
    
    func testJavaScriptDensity() {
        let data = Data("const x = 1;\nfunction foo() {\n  return x => x + 1;\n}\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .javascript)
    }
    
    func testCSS() {
        let data = Data(".class {\n  color: red;\n  margin: 0;\n}\n".utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .css)
    }
    
    func testEmptyData() {
        let data = Data()
        XCTAssertNil(ContentSniffer.sniffLanguage(data))
    }
    
    func testNonUTF8Data() {
        // Binary data that is not valid text
        let data = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        // Should not crash; may return nil
        _ = ContentSniffer.sniffLanguage(data)
    }
    
    func testSwiftImportsDoNotSniffAsPython() {
        let data = Data("""
        import Foundation
        import AppKit
        
        class FileLoader {
            func load() {
                let value = 1
            }
        }
        """.utf8)
        XCTAssertNotEqual(ContentSniffer.sniffLanguage(data), .python)
    }
    
    func testTypeScriptSniffsAsTypeScriptNotJavaScript() {
        let data = Data("""
        interface User {
            name: string
            age: number
        }
        const first = 1;
        const second = 2;
        """.utf8)
        XCTAssertEqual(ContentSniffer.sniffLanguage(data), .typescript)
    }
    
    func testUnknownExtensionStillSniffs() {
        let data = Data("""
        def main():
            print('hi')
        """.utf8)
        XCTAssertEqual(
            ContentSniffer.resolveLanguage(fileName: "mystery.xyz", data: data),
            .python
        )
    }
    
    func testRecognizedExtensionWinsOverContent() {
        let pythonLooking = Data("""
        import os
        import sys
        
        def main():
            print('hi')
        """.utf8)
        XCTAssertEqual(
            ContentSniffer.resolveLanguage(fileName: "Main.swift", data: pythonLooking),
            .swift
        )
        
        let javaScriptLooking = Data("const x = 1;\nconst y = 2;\n".utf8)
        XCTAssertEqual(
            ContentSniffer.resolveLanguage(fileName: "app.ts", data: javaScriptLooking),
            .typescript
        )
    }
}
