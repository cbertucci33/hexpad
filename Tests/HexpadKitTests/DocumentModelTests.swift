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

    // MARK: - Card 79e2f323: quit loses untitled edits / tab switch clears undo

    func testEditedFromEmptyUntitledReportsUnsaved() {
        let doc = DocumentModel()               // untitled, empty
        XCTAssertFalse(doc.unsavedChanges)
        doc.text = "typed without ever saving"  // the old `!isEmpty` guard
        XCTAssertTrue(doc.unsavedChanges)        // reported "clean" → lost work
    }

    func testEachDocumentHasOwnUndoManager() {
        let a = DocumentModel()
        let b = DocumentModel()
        XCTAssertFalse(a.undoManager === b.undoManager)
    }

    func testUndoStacksAreIsolatedPerDocument() {
        let a = DocumentModel()
        let b = DocumentModel()
        a.undoManager.registerUndo(withTarget: a) { _ in }
        XCTAssertTrue(a.undoManager.canUndo)
        XCTAssertFalse(b.undoManager.canUndo, "tab switch must not share/clobber stacks")
        b.undoManager.removeAllActions()
        XCTAssertTrue(a.undoManager.canUndo, "undoing in b cannot wipe a")
    }

    func testUntitledBufferSurvivesSessionRoundTrip() {
        let store = TabStore()
        let doc = DocumentModel()
        doc.text = "untitled draft"
        store.addDocument(doc)
        let restored = TabStore.fromSessionData(store.toSessionData())
        XCTAssertEqual(restored.documents.count, 1)
        XCTAssertEqual(restored.documents.first?.text, "untitled draft")
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

    // isModified used to compare on-disk mtime, which typing never changes.
    func testFileBackedTypingMarksModified() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-isdirty-\(UUID().uuidString).txt")
        try "original".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let doc = DocumentModel(text: "original", filePath: tmp)
        XCTAssertFalse(doc.isModified)
        doc.text = "edited"
        XCTAssertTrue(doc.isModified, "typing in a saved file must mark it dirty")
        doc.setModified(false)
        XCTAssertFalse(doc.isModified)
    }

    // Paths with spaces must survive a session round trip (URL(string:) broke them).
    func testSessionRoundTripPathWithSpaces() {
        let path = "/tmp/hexpad dir name/file one.txt"
        let doc = DocumentModel(text: "x", filePath: URL(fileURLWithPath: path))
        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)
        XCTAssertNotNil(restored, "doc with spaces in its path must restore")
    }

    func testIsModifiedUntitledFollowsText() {
        let doc = DocumentModel(text: "a")
        XCTAssertFalse(doc.isModified)
        doc.text = "b"
        XCTAssertTrue(doc.isModified)
    }
}
