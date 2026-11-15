import XCTest
import AppKit
@testable import HexpadKit

final class DocumentModelTests: XCTestCase {

    /// Attaches a real NSTextView to the document's storage the same way
    /// EditorContainer does, so tests exercise the shared buffer rather than a
    /// stand-in.
    private func makeTextView(for doc: DocumentModel) -> NSTextView {
        let layoutManager = NSLayoutManager()
        doc.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        layoutManager.addTextContainer(container)
        return NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                          textContainer: container)
    }

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

    // MARK: - Shared buffer: model edits are visible in the attached editor

    func testReplaceCharactersIsVisibleInSharedTextView() {
        let doc = DocumentModel(text: "hello world")
        let textView = makeTextView(for: doc)

        doc.replaceCharacters(in: NSRange(location: 0, length: 5), with: "goodbye")

        XCTAssertEqual(doc.text, "goodbye world")
        XCTAssertEqual(textView.string, "goodbye world", "find/replace must update the visible editor")
        XCTAssertTrue(doc.undoManager.canUndo)
    }

    func testTextViewTypingWritesThroughToModel() {
        let doc = DocumentModel(text: "hello")
        let textView = makeTextView(for: doc)

        let end = (doc.text as NSString).length
        textView.insertText("!", replacementRange: NSRange(location: end, length: 0))

        XCTAssertEqual(textView.string, "hello!")
        XCTAssertEqual(doc.text, "hello!", "typing must update the model without a copy step")
        XCTAssertTrue(doc.isModified)
    }

    func testReplaceAllUndoRestoresVisibleText() {
        let doc = DocumentModel(text: "alpha beta")
        let textView = makeTextView(for: doc)

        doc.replaceAllText(with: "gamma")
        XCTAssertEqual(textView.string, "gamma")

        doc.undoManager.undo()
        XCTAssertEqual(doc.text, "alpha beta")
        XCTAssertEqual(textView.string, "alpha beta", "undo must restore the visible buffer")

        doc.undoManager.redo()
        XCTAssertEqual(textView.string, "gamma")
    }

    func testProgrammaticReplaceUsesOnlyThisDocumentsUndoStack() {
        let edited = DocumentModel(text: "hello world")
        let other = DocumentModel(text: "other")

        edited.replaceCharacters(in: NSRange(location: 0, length: 5), with: "goodbye")

        XCTAssertEqual(edited.text, "goodbye world")
        XCTAssertTrue(edited.isModified)
        XCTAssertTrue(edited.undoManager.canUndo)
        XCTAssertFalse(other.undoManager.canUndo, "an edit must not touch another tab's stack")

        edited.undoManager.undo()
        XCTAssertEqual(edited.text, "hello world")
        XCTAssertFalse(edited.isModified)
    }

    func testUndoSurvivesStorageRebindBetweenTabs() {
        let first = DocumentModel(text: "alpha")
        let second = DocumentModel(text: "beta")
        let textView = makeTextView(for: first)
        let layoutManager = textView.layoutManager!

        first.replaceAllText(with: "ALPHA")
        XCTAssertEqual(textView.string, "ALPHA")

        // Same swap EditorContainer.bind(to:) performs on a tab switch.
        layoutManager.replaceTextStorage(second.textStorage)
        XCTAssertEqual(textView.string, "beta")
        second.replaceAllText(with: "BETA")

        layoutManager.replaceTextStorage(first.textStorage)
        XCTAssertEqual(textView.string, "ALPHA", "returning to a tab keeps its edits")

        first.undoManager.undo()
        XCTAssertEqual(textView.string, "alpha", "undo applies to the visible buffer")
        XCTAssertEqual(second.text, "BETA", "the other tab's edits are untouched")
    }

    func testEOLConversionIsVisibleAndUndoable() {
        let doc = DocumentModel(text: "a\nb")
        let textView = makeTextView(for: doc)

        doc.convertEOL(to: "CRLF")
        XCTAssertEqual(textView.string, "a\r\nb")

        doc.undoManager.undo()
        XCTAssertEqual(textView.string, "a\nb")
    }

    func testReloadTextIsCleanAndUndoable() {
        let doc = DocumentModel(text: "old")
        let textView = makeTextView(for: doc)

        doc.reloadText("from disk")

        XCTAssertEqual(textView.string, "from disk")
        XCTAssertFalse(doc.isModified, "external reload becomes the clean baseline")
        XCTAssertTrue(doc.undoManager.canUndo, "external reload is undoable")

        doc.undoManager.undo()
        XCTAssertEqual(textView.string, "old")
        XCTAssertTrue(doc.isModified)
    }

    // FindBar's live count/highlight path keys off this notification; a
    // programmatic replace must reach observers with the edited document.
    func testProgrammaticEditPostsTextDidChangeNotification() {
        let doc = DocumentModel(text: "alpha")
        let expectation = expectation(description: "model text change posted")
        let token = NotificationCenter.default.addObserver(
            forName: DocumentModel.textDidChangeNotification,
            object: doc,
            queue: nil
        ) { note in
            XCTAssertTrue((note.object as? DocumentModel) === doc)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        doc.replaceCharacters(in: NSRange(location: 0, length: 5), with: "beta")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(doc.text, "beta")
    }
}
