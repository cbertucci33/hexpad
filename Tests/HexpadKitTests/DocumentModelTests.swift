import XCTest
@testable import HexpadKit

final class DocumentModelTests: XCTestCase {
    func testInitialState() {
        let doc = DocumentModel(text: "hello")
        XCTAssertEqual(doc.text, "hello")
        XCTAssertTrue(doc.isUntitled)
        XCTAssertFalse(doc.unsavedChanges)
        XCTAssertEqual(doc.encoding, "UTF-8")
        XCTAssertEqual(doc.eolType, "LF")
        XCTAssertEqual(doc.language, "Plain Text")
    }
    
    func testModifiedState() {
        let doc = DocumentModel(text: "hello", filePath: URL(fileURLWithPath: "/tmp/test.txt"))
        doc.text = "world"
        XCTAssertTrue(doc.unsavedChanges)
        doc.setModified(false)
        XCTAssertFalse(doc.unsavedChanges)
    }
    
    func testEOLConversion() {
        var doc = DocumentModel(text: "a\nb\nc")
        doc.convertEOL(to: "CRLF")
        XCTAssertEqual(doc.text, "a\r\nb\r\nc")
        XCTAssertEqual(doc.eolType, "CRLF")
        
        doc.convertEOL(to: "LF")
        XCTAssertEqual(doc.text, "a\nb\nc")
        XCTAssertEqual(doc.eolType, "LF")
        
        doc.convertEOL(to: "CR")
        XCTAssertEqual(doc.text, "a\rb\rc")
        XCTAssertEqual(doc.eolType, "CR")
    }
    
    func testSessionRoundTrip() {
        let doc = DocumentModel(text: "test", filePath: URL(fileURLWithPath: "/tmp/test.txt"), encoding: "UTF-8", eolType: "CRLF")
        doc.setLanguage("Python")
        
        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)
        
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.text, "test")
        XCTAssertEqual(restored?.encoding, "UTF-8")
        XCTAssertEqual(restored?.eolType, "CRLF")
        XCTAssertEqual(restored?.language, "Python")
    }
    
    func testSessionWithoutFilePath() {
        let doc = DocumentModel(text: "untitled")
        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)
        XCTAssertNotNil(restored)
        XCTAssertNotNil(restored?.id)
    }
    
    // Saving ASCII-encoded text containing emoji must throw, not write an empty file.
    func testSaveASCIIWithEmojiThrows() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        
        let doc = DocumentModel(text: "😀 hello", filePath: tmp, encoding: "ASCII")
        XCTAssertThrowsError(try doc.save()) { error in
            XCTAssert(error is DocumentError)
        }
        
        // save() must throw BEFORE writing: no file should exist at all.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "save wrote a file despite unencodable text")
    }
}
