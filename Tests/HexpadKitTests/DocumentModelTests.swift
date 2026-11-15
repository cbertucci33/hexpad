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

    // MARK: - EOL detection and preservation

    func testInitialEOLDetectedFromText() {
        XCTAssertEqual(DocumentModel(text: "a\r\nb").eolType, "CRLF")
        XCTAssertEqual(DocumentModel(text: "a\nb").eolType, "LF")
        XCTAssertEqual(DocumentModel(text: "a\rb").eolType, "CR")
        XCTAssertEqual(DocumentModel(text: "").eolType, "LF", "empty documents use the LF default")
    }

    func testExplicitEOLTypeOverridesDetection() {
        let doc = DocumentModel(text: "a\r\nb", eolType: "CR")
        XCTAssertEqual(doc.eolType, "CR")
    }

    func testSavePreservesCRLF() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-eol-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "one\r\ntwo\r\n".write(to: tmp, atomically: true, encoding: .utf8)
        let onDisk = try String(contentsOf: tmp, encoding: .utf8)

        let doc = DocumentModel(text: onDisk, filePath: tmp)
        XCTAssertEqual(doc.eolType, "CRLF", "opening a CRLF file must record its style")

        // The editor buffer uses LF; saving must put CRLF back on disk.
        doc.text = "one\ntwo\nthree\n"
        try doc.save()

        let saved = try Data(contentsOf: tmp)
        XCTAssertEqual(saved, Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    func testSavePreservesCR() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-eol-cr-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "one\rtwo\r".write(to: tmp, atomically: true, encoding: .utf8)
        let onDisk = try String(contentsOf: tmp, encoding: .utf8)

        let doc = DocumentModel(text: onDisk, filePath: tmp)
        XCTAssertEqual(doc.eolType, "CR")

        doc.text = "one\ntwo\nthree\n"
        try doc.save()

        XCTAssertEqual(try Data(contentsOf: tmp), Data("one\rtwo\rthree\r".utf8))
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

    // MARK: - Encode in / Convert to

    /// "Encode in" reinterprets the same bytes with another decoder. Encoding
    /// the reinterpreted text back with that decoder restores the original
    /// bytes, and decoding those as UTF-8 yields the original text.
    func testEncodeInRoundTripReturnsOriginalText() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-encode-in-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // An even byte count so the UTF-8 stream is a whole number of UTF-16
        // code units; every pair is a BMP character, never a surrogate.
        let original = "hello\nworld!"
        let utf8Data = Data(original.utf8)
        XCTAssertEqual(utf8Data.count % 2, 0)
        try utf8Data.write(to: tmp)

        let doc = DocumentModel(text: original, filePath: tmp, encoding: "UTF-8")
        XCTAssertTrue(doc.redecodeFromDisk(as: "UTF-16LE"))

        let reinterpreted = doc.text
        XCTAssertNotEqual(reinterpreted, original, "the bytes must be re-decoded, not transcoded")
        XCTAssertEqual(doc.encoding, "UTF-16LE")

        let back = try XCTUnwrap(reinterpreted.data(using: .utf16LittleEndian))
        XCTAssertEqual(back, utf8Data, "encoding back must reproduce the file's bytes")
        XCTAssertEqual(String(data: back, encoding: .utf8), original,
                       "the original UTF-8 text decodes from those bytes")

        // The operation is a reinterpretation, not a conversion: same bytes on
        // disk and a clean buffer.
        XCTAssertEqual(try Data(contentsOf: tmp), utf8Data)
        XCTAssertFalse(doc.isModified)
    }

    func testEncodeInReadsAUTF16FileWithTheChosenDecoder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-encode-in-utf16-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = "héllo\nwörld"
        let utf16Data = try XCTUnwrap(original.data(using: .utf16LittleEndian))
        try utf16Data.write(to: tmp)

        // Open with the wrong (default) decoder, then fix it via "Encode in".
        let doc = DocumentModel(text: "", filePath: tmp, encoding: "UTF-8")
        XCTAssertTrue(doc.redecodeFromDisk(as: "UTF-16LE"))

        XCTAssertEqual(doc.text, original)
        XCTAssertEqual(doc.encoding, "UTF-16LE")
        XCTAssertEqual(doc.saveEncoding, "UTF-16LE")
        XCTAssertFalse(doc.isModified, "a faithful re-decode is the clean baseline")
        XCTAssertEqual(try Data(contentsOf: tmp), utf16Data, "Encode in must not rewrite the file")

        // Saving without edits writes the very same bytes back.
        try doc.save()
        XCTAssertEqual(try Data(contentsOf: tmp), utf16Data)
    }

    func testEncodeInNeedsRawBytesOnDisk() {
        let doc = DocumentModel(text: "untitled")
        XCTAssertFalse(doc.redecodeFromDisk(as: "UTF-8"),
                       "no file means there are no raw bytes to reinterpret")
    }

    func testConvertToThenSaveWritesTargetEncoding() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-convert-to-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("héllo".utf8).write(to: tmp)
        let doc = DocumentModel(text: "héllo", filePath: tmp, encoding: "UTF-8")
        XCTAssertFalse(doc.isModified)

        XCTAssertTrue(doc.canEncode(as: "UTF-16LE"))
        try doc.convertEncoding(to: "UTF-16LE")

        XCTAssertEqual(doc.encoding, "UTF-8", "Convert to does not re-decode the buffer")
        XCTAssertEqual(doc.saveEncoding, "UTF-16LE", "the next save uses the target encoding")
        XCTAssertTrue(doc.isModified, "a pending conversion must dirty the document")

        try doc.save()

        let expected = try XCTUnwrap("héllo".data(using: .utf16LittleEndian))
        let saved = try Data(contentsOf: tmp)
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(String(data: saved, encoding: .utf16LittleEndian), "héllo")
        XCTAssertFalse(doc.isModified)
    }

    func testConvertToUnsupportedEncodingThrowsAndKeepsTarget() {
        let doc = DocumentModel(text: "😀", encoding: "UTF-8")

        XCTAssertFalse(doc.canEncode(as: "ASCII"))
        XCTAssertThrowsError(try doc.convertEncoding(to: "ASCII")) { error in
            XCTAssert(error is DocumentError)
        }
        XCTAssertEqual(doc.saveEncoding, "UTF-8", "a failed conversion must not retarget the save")
        XCTAssertFalse(doc.isModified)
    }
}
