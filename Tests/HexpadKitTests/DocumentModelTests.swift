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

    /// Simulates opening `url` the way the editor does: the buffer is
    /// normalized to LF-only, while the file's original line-ending style is
    /// recorded so the next save writes it back.
    private func openDocumentKeepingFileEOL(at url: URL) throws -> DocumentModel {
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        return DocumentModel(text: EOLDetective.converting(raw, to: "LF"),
                             filePath: url,
                             eolType: EOLDetective.detect(data))
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
        let doc = DocumentModel(text: "a\nb\nc")
        XCTAssertFalse(doc.isModified)

        doc.convertEOL(to: "CRLF")
        XCTAssertEqual(doc.text, "a\nb\nc", "the buffer must stay LF-only")
        XCTAssertEqual(doc.eolType, "CRLF")
        XCTAssertTrue(doc.isModified, "changing the save style must mark the document modified")

        doc.convertEOL(to: "LF")
        XCTAssertEqual(doc.text, "a\nb\nc")
        XCTAssertEqual(doc.eolType, "LF")
        XCTAssertTrue(doc.isModified)

        doc.convertEOL(to: "CR")
        XCTAssertEqual(doc.text, "a\nb\nc", "converting to CR must not put lone \\r into the buffer")
        XCTAssertEqual(doc.eolType, "CR")
        XCTAssertTrue(doc.isModified)
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

    /// Converting a CRLF document to LF must leave the LF-only buffer byte
    /// identical and only change the bytes written by save().
    func testConvertCRLFToLFThenSaveWritesLFWithLFBuffer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-convert-eol-lf-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: tmp)
        let doc = try openDocumentKeepingFileEOL(at: tmp)
        XCTAssertEqual(doc.eolType, "CRLF")
        XCTAssertEqual(doc.text, "one\ntwo\nthree\n", "the buffer is LF-only")
        XCTAssertFalse(doc.isModified)

        doc.convertEOL(to: "LF")
        XCTAssertEqual(doc.text, "one\ntwo\nthree\n", "convertEOL must not touch the buffer")
        XCTAssertEqual(doc.eolType, "LF")
        XCTAssertTrue(doc.isModified)

        doc.replaceCharacters(in: NSRange(location: 4, length: 3), with: "TWO")
        XCTAssertEqual(doc.text, "one\nTWO\nthree\n")
        try doc.save()

        XCTAssertEqual(try Data(contentsOf: tmp), Data("one\nTWO\nthree\n".utf8))
        XCTAssertFalse(doc.isModified)
    }

    /// The CR variant: the buffer stays LF-only, but save() writes lone CR
    /// bytes for a document converted to the classic-Mac style.
    func testConvertCRLFToCRThenSaveWritesCRWithLFBuffer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-convert-eol-cr-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: tmp)
        let doc = try openDocumentKeepingFileEOL(at: tmp)
        XCTAssertEqual(doc.eolType, "CRLF")
        XCTAssertEqual(doc.text, "one\ntwo\nthree\n")

        doc.convertEOL(to: "CR")
        XCTAssertEqual(doc.text, "one\ntwo\nthree\n", "the buffer must not gain lone \\r")
        XCTAssertEqual(doc.eolType, "CR")
        XCTAssertTrue(doc.isModified)

        doc.replaceCharacters(in: NSRange(location: 4, length: 3), with: "TWO")
        XCTAssertFalse(doc.text.contains("\r"), "line-based subsystems require LF-only text")
        try doc.save()

        XCTAssertEqual(try Data(contentsOf: tmp), Data("one\rTWO\rthree\r".utf8))
        XCTAssertEqual(doc.text, "one\nTWO\nthree\n", "saving must not rewrite the buffer")
        XCTAssertFalse(doc.isModified)
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

    func testEOLConversionLeavesVisibleBufferAndUndoStackUntouched() {
        let doc = DocumentModel(text: "a\nb")
        let textView = makeTextView(for: doc)

        doc.convertEOL(to: "CRLF")

        XCTAssertEqual(textView.string, "a\nb", "line endings are applied on save, not in the editor")
        XCTAssertEqual(doc.eolType, "CRLF")
        XCTAssertTrue(doc.isModified, "a pending save conversion dirties the document")
        XCTAssertFalse(doc.undoManager.canUndo, "an EOL conversion is not a text edit")
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

    // MARK: - Session projection of "Convert to" and BOM state

    func testSessionDataCarriesSaveEncodingAndPendingConversion() throws {
        let doc = DocumentModel(text: "héllo", encoding: "UTF-8")
        try doc.convertEncoding(to: "UTF-16LE")

        let data = doc.toSessionData()

        XCTAssertEqual(data["encoding"] as? String, "UTF-8")
        XCTAssertEqual(data["saveEncoding"] as? String, "UTF-16LE")
        XCTAssertEqual(data["saveConversionPending"] as? Bool, true)

        let restored = try XCTUnwrap(DocumentModel.fromSessionData(data))
        XCTAssertEqual(restored.encoding, "UTF-8", "Convert to does not change the decode encoding")
        XCTAssertEqual(restored.saveEncoding, "UTF-16LE")
        XCTAssertTrue(restored.hasPendingSaveConversion)
        XCTAssertTrue(restored.unsavedChanges, "a pending conversion must survive the round trip")
    }

    func testLegacySessionWithoutConversionKeysHasNoPendingConversion() throws {
        // Exactly the shape sessions had before saveEncoding/keepsBOM existed.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "text": "legacy text",
            "name": "legacy.txt",
            "encoding": "Windows-1252",
            "eolType": "LF",
            "language": "Plain Text",
            "isModified": false
        ]

        let restored = try XCTUnwrap(DocumentModel.fromSessionData(legacy))

        XCTAssertEqual(restored.saveEncoding, "Windows-1252", "missing key falls back to the decode encoding")
        XCTAssertFalse(restored.hasPendingSaveConversion)
        XCTAssertFalse(restored.keepsBOM)
        XCTAssertFalse(restored.unsavedChanges)
    }

    func testSaveReEmitsUTF16LEBOM() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-bom-save-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let doc = DocumentModel(text: "hello", filePath: tmp, encoding: "UTF-16LE")
        doc.keepsBOM = true
        try doc.save()

        let saved = try Data(contentsOf: tmp)
        XCTAssertTrue(saved.starts(with: Data([0xFF, 0xFE])), "the BOM must be written back")
        XCTAssertEqual(String(data: EncodingDetective.strippingBOM(from: saved),
                              encoding: .utf16LittleEndian),
                       "hello")
        XCTAssertEqual(try doc.toSessionData()["keepsBOM"] as? Bool, true)
    }

    func testSaveDoesNotInventBOMWhenTheFileHadNone() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-no-bom-save-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let doc = DocumentModel(text: "hello", filePath: tmp, encoding: "UTF-16LE")
        XCTAssertFalse(doc.keepsBOM)
        try doc.save()

        let saved = try Data(contentsOf: tmp)
        XCTAssertEqual(saved, "hello".data(using: .utf16LittleEndian))
    }

    func testExternalChangeFlagIsClearedWhenTheBufferSettles() {
        let doc = DocumentModel(text: "draft")
        doc.noteExternalChange()
        XCTAssertTrue(doc.hasExternalChange)

        doc.setModified(false)

        XCTAssertFalse(doc.hasExternalChange, "settling the buffer resolves the conflict")
    }

    // MARK: - Per-document editor state (caret, scroll, wrap, zoom)

    func testEditorStateDefaultsOnFreshDocument() {
        let doc = DocumentModel(text: "hello")

        XCTAssertEqual(doc.caretRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(doc.scrollOffset, .zero)
        XCTAssertFalse(doc.wordWrapEnabled)
        XCTAssertEqual(doc.zoomScale, 1.0)
        XCTAssertEqual(doc.editorState, DocumentEditorState())
    }

    func testEditorStateRoundTripsThroughSessionData() {
        let doc = DocumentModel(text: "one\ntwo\nthree")
        doc.caretRange = NSRange(location: 4, length: 3)
        doc.scrollOffset = CGPoint(x: 12.5, y: 240.75)
        doc.wordWrapEnabled = true
        doc.zoomScale = 1.4

        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.caretRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(restored?.scrollOffset.x ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertEqual(restored?.scrollOffset.y ?? -1, 240.75, accuracy: 0.0001)
        XCTAssertTrue(restored?.wordWrapEnabled ?? false)
        XCTAssertEqual(restored?.zoomScale ?? 0, 1.4, accuracy: 0.0001)
    }

    func testEditorStateRoundTripsForUntitledDocument() {
        let doc = DocumentModel()
        doc.text = "untitled draft"
        doc.caretRange = NSRange(location: 2, length: 0)
        doc.scrollOffset = CGPoint(x: 0, y: 33)
        doc.wordWrapEnabled = true
        doc.zoomScale = 0.8

        let restored = DocumentModel.fromSessionData(doc.toSessionData())

        XCTAssertNotNil(restored)
        XCTAssertTrue(restored?.isUntitled ?? false)
        XCTAssertEqual(restored?.text, "untitled draft")
        XCTAssertEqual(restored?.caretRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(restored?.scrollOffset.y ?? -1, 33, accuracy: 0.0001)
        XCTAssertTrue(restored?.wordWrapEnabled ?? false)
        XCTAssertEqual(restored?.zoomScale ?? 0, 0.8, accuracy: 0.0001)
    }

    func testLegacySessionDataWithoutEditorStateUsesDefaults() {
        // Exactly the shape sessions had before this slice: no editorState key.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "text": "legacy text",
            "name": "legacy.txt",
            "encoding": "UTF-8",
            "eolType": "LF",
            "language": "Plain Text",
            "isModified": false
        ]

        let restored = DocumentModel.fromSessionData(legacy)

        XCTAssertNotNil(restored, "old session entries must still restore")
        XCTAssertEqual(restored?.text, "legacy text")
        XCTAssertEqual(restored?.editorState, DocumentEditorState.default)
        XCTAssertEqual(restored?.caretRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(restored?.scrollOffset, CGPoint.zero)
        XCTAssertFalse(restored?.wordWrapEnabled ?? true)
        XCTAssertEqual(restored?.zoomScale ?? 0, 1.0)
    }

    func testPartialEditorStateUsesDefaultsForMissingKeys() {
        // Future/partial writers may supply only some fields; each missing key
        // falls back independently instead of discarding the whole state.
        let partial: [String: Any] = [
            "id": UUID().uuidString,
            "text": "partial",
            "name": "partial.txt",
            "encoding": "UTF-8",
            "eolType": "LF",
            "language": "Plain Text",
            "editorState": [
                "caretLocation": 3,
                "wordWrap": true
            ]
        ]

        let restored = DocumentModel.fromSessionData(partial)

        XCTAssertEqual(restored?.caretRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(restored?.scrollOffset, CGPoint.zero)
        XCTAssertTrue(restored?.wordWrapEnabled ?? false)
        XCTAssertEqual(restored?.zoomScale ?? 0, 1.0)
    }

    func testEditorStateIsIndependentPerDocument() {
        let first = DocumentModel(text: "first document")
        let second = DocumentModel(text: "second document")
        first.caretRange = NSRange(location: 5, length: 1)
        first.scrollOffset = CGPoint(x: 0, y: 100)
        first.wordWrapEnabled = true
        first.zoomScale = 1.5

        second.caretRange = NSRange(location: 2, length: 0)
        second.scrollOffset = CGPoint(x: 10, y: 20)
        second.wordWrapEnabled = false
        second.zoomScale = 0.9

        XCTAssertNotEqual(first.editorState, second.editorState)

        let store = TabStore()
        store.addDocument(first)
        store.addDocument(second)
        let restored = TabStore.fromSessionData(store.toSessionData())

        XCTAssertEqual(restored.documents.count, 2)
        XCTAssertEqual(restored.documents[0].caretRange, NSRange(location: 5, length: 1))
        XCTAssertEqual(restored.documents[0].scrollOffset.y, 100, accuracy: 0.0001)
        XCTAssertTrue(restored.documents[0].wordWrapEnabled)
        XCTAssertEqual(restored.documents[0].zoomScale, 1.5, accuracy: 0.0001)

        XCTAssertEqual(restored.documents[1].caretRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(restored.documents[1].scrollOffset, CGPoint(x: 10, y: 20))
        XCTAssertFalse(restored.documents[1].wordWrapEnabled)
        XCTAssertEqual(restored.documents[1].zoomScale, 0.9, accuracy: 0.0001)
    }

    // MARK: - Per-document fold state

    /// Five folds of mixed kinds, deliberately nested inside a surrounding
    /// brace fold, which is the real-world shape a session has to carry.
    private func mixedFoldState(in text: String) -> (state: FoldState, folds: [FoldRange]) {
        let nsText = text as NSString
        let parensStart = nsText.range(of: "()").location
        let bracketsStart = nsText.range(of: "[1, 2]").location
        let commentStart = nsText.range(of: "/*").location
        let commentEnd = NSMaxRange(nsText.range(of: "*/"))

        let folds = [
            FoldRange(location: 0, length: nsText.length, kind: .braces),
            FoldRange(location: parensStart, length: 2, kind: .parentheses),
            FoldRange(location: bracketsStart, length: 6, kind: .brackets),
            FoldRange(location: commentStart,
                      length: commentEnd - commentStart,
                      kind: .blockComment),
            FoldRange(location: nsText.range(of: "// region").location,
                      length: ("// region" as NSString).length,
                      kind: .region)
        ]

        var state = FoldState()
        for fold in folds { state.insert(fold) }
        return (state, folds)
    }

    func testFoldStateDefaultsToEmptyOnFreshDocument() {
        let doc = DocumentModel(text: "hello")

        XCTAssertTrue(doc.foldState.isEmpty)
        XCTAssertEqual(doc.foldState, FoldState())
        XCTAssertEqual(doc.foldState.count, 0)
    }

    func testFoldStateRoundTripsThroughSessionData() {
        let text = """
        func outer() {
            let values = [1, 2]
            /* block
               comment */
            // region
        }
        """
        let doc = DocumentModel(text: text)
        let (state, folds) = mixedFoldState(in: text)
        doc.foldState = state

        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.foldState, state)
        XCTAssertEqual(restored?.foldState.count, folds.count)

        // FoldState equality ignores kind (FoldRange identity is its span), so
        // verify each kind survived the projection explicitly.
        let restoredFolds = restored?.foldState.collapsedRanges ?? []
        for fold in folds {
            XCTAssertTrue(restoredFolds.contains { $0.range == fold.range && $0.kind == fold.kind },
                          "missing \(fold.kind.rawValue) fold at \(fold.range)")
        }
    }

    func testEmptyFoldStateRoundTripsThroughSessionData() {
        let doc = DocumentModel(text: "no folds here")
        doc.foldState = FoldState()

        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)

        let foldStateData = data["foldState"] as? [String: Any]
        XCTAssertNotNil(foldStateData, "the key is written even when nothing is collapsed")
        XCTAssertEqual((foldStateData?["collapsedRanges"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(restored?.foldState, FoldState())
        XCTAssertTrue(restored?.foldState.isEmpty ?? false)
    }

    func testLegacySessionDataWithoutFoldStateRestoresEmptyState() {
        // Exactly the shape sessions had before fold persistence: no
        // "foldState" key at all.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "text": "legacy text",
            "name": "legacy.txt",
            "encoding": "UTF-8",
            "eolType": "LF",
            "language": "Plain Text",
            "isModified": false
        ]

        let restored = DocumentModel.fromSessionData(legacy)

        XCTAssertNotNil(restored, "old session entries must still restore")
        XCTAssertEqual(restored?.text, "legacy text")
        XCTAssertEqual(restored?.foldState, FoldState())
        XCTAssertTrue(restored?.foldState.isEmpty ?? false)
    }

    func testMalformedFoldStateEntriesAreSkippedIndividually() {
        let valid: [String: Any] = [
            "location": 4,
            "length": 10,
            "kind": "braces"
        ]
        let unknownKind: [String: Any] = [
            "location": 20,
            "length": 5,
            "kind": "fromAFutureBuild"
        ]
        let negativeLocation: [String: Any] = [
            "location": -1,
            "length": 5,
            "kind": "parentheses"
        ]
        let partial: [String: Any] = [
            "id": UUID().uuidString,
            "text": "folds",
            "name": "folds.swift",
            "encoding": "UTF-8",
            "eolType": "LF",
            "language": "Swift",
            "foldState": [
                "collapsedRanges": [valid, unknownKind, negativeLocation]
            ]
        ]

        let restored = DocumentModel.fromSessionData(partial)

        XCTAssertEqual(restored?.foldState.count, 1)
        XCTAssertTrue(restored?.foldState.isCollapsed(NSRange(location: 4, length: 10)) ?? false)
    }

    func testFoldStateIsIndependentPerDocumentAndSurvivesTabStoreRoundTrip() {
        let firstText = "func first() {\n    // region\n}"
        let secondText = "func second() {\n    let x = [1, 2]\n}"
        let first = DocumentModel(text: firstText)
        let second = DocumentModel(text: secondText)
        let firstTextNS = firstText as NSString
        var firstState = FoldState()
        firstState.insert(FoldRange(location: 0, length: firstTextNS.length, kind: .braces))
        firstState.insert(FoldRange(location: firstTextNS.range(of: "()").location,
                                    length: 2,
                                    kind: .parentheses))
        firstState.insert(FoldRange(location: firstTextNS.range(of: "// region").location,
                                    length: 9,
                                    kind: .region))
        var secondState = FoldState()
        secondState.insert(FoldRange(location: 0,
                                     length: (secondText as NSString).length,
                                     kind: .braces))
        first.foldState = firstState
        second.foldState = secondState

        XCTAssertNotEqual(first.foldState, second.foldState)

        let store = TabStore()
        store.addDocument(first)
        store.addDocument(second)
        let restored = TabStore.fromSessionData(store.toSessionData())

        XCTAssertEqual(restored.documents.count, 2)
        XCTAssertEqual(restored.documents[0].foldState, firstState)
        XCTAssertEqual(restored.documents[1].foldState, secondState)
    }

    // MARK: - Per-document bookmark state

    func testBookmarkStateDefaultsToEmptyOnFreshDocument() {
        let doc = DocumentModel(text: "hello")

        XCTAssertTrue(doc.bookmarkState.isEmpty)
        XCTAssertEqual(doc.bookmarkState, BookmarkState())
        XCTAssertEqual(doc.bookmarkState.count, 0)
    }

    func testBookmarkStateRoundTripsThroughSessionDataWithNotes() {
        let doc = DocumentModel(text: "one\ntwo\nthree\nfour")
        var state = BookmarkState()
        state.add(line: 3, note: "look here")
        state.add(line: 1, note: "start")
        doc.bookmarkState = state

        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.bookmarkState, state)
        XCTAssertEqual(restored?.bookmarkState.lines, [1, 3])
        XCTAssertEqual(restored?.bookmarkState.note(forLine: 1), "start")
        XCTAssertEqual(restored?.bookmarkState.note(forLine: 3), "look here")
    }

    func testBookmarkStateRoundTripsThroughSessionDataWithoutNotes() {
        let doc = DocumentModel(text: "one\ntwo\nthree\nfour")
        var state = BookmarkState()
        state.add(line: 4)
        state.add(line: 2)
        doc.bookmarkState = state

        let restored = DocumentModel.fromSessionData(doc.toSessionData())

        XCTAssertEqual(restored?.bookmarkState, state)
        XCTAssertEqual(restored?.bookmarkState.lines, [2, 4])
        XCTAssertNil(restored?.bookmarkState.note(forLine: 2))
        XCTAssertNil(restored?.bookmarkState.note(forLine: 4))
    }

    func testEmptyBookmarkStateRoundTripsThroughSessionData() {
        let doc = DocumentModel(text: "no bookmarks here")
        doc.bookmarkState = BookmarkState()

        let data = doc.toSessionData()
        let restored = DocumentModel.fromSessionData(data)

        let bookmarkStateData = data["bookmarkState"] as? [String: Any]
        XCTAssertNotNil(bookmarkStateData, "the key is written even when nothing is bookmarked")
        XCTAssertEqual((bookmarkStateData?["bookmarks"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(restored?.bookmarkState, BookmarkState())
        XCTAssertTrue(restored?.bookmarkState.isEmpty ?? false)
    }

    func testLegacySessionDataWithoutBookmarkStateRestoresEmptyState() {
        // Exactly the shape sessions had before bookmark persistence: no
        // "bookmarkState" key at all.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "text": "legacy text",
            "name": "legacy.txt",
            "encoding": "UTF-8",
            "eolType": "LF",
            "language": "Plain Text",
            "isModified": false
        ]

        let restored = DocumentModel.fromSessionData(legacy)

        XCTAssertNotNil(restored, "old session entries must still restore")
        XCTAssertEqual(restored?.text, "legacy text")
        XCTAssertEqual(restored?.bookmarkState, BookmarkState())
        XCTAssertTrue(restored?.bookmarkState.isEmpty ?? false)
    }

    func testMalformedBookmarkStateEntriesAreSkippedIndividually() {
        let valid: [String: Any] = [
            "line": 2,
            "note": "kept"
        ]
        let missingLine: [String: Any] = [
            "note": "no line"
        ]
        let nonPositiveLine: [String: Any] = [
            "line": 0
        ]
        let stringLine: [String: Any] = [
            "line": "3"
        ]
        let nonStringNote: [String: Any] = [
            "line": 4,
            "note": 99
        ]
        let partial: [String: Any] = [
            "id": UUID().uuidString,
            "text": "bookmarks",
            "name": "bookmarks.swift",
            "encoding": "UTF-8",
            "eolType": "LF",
            "language": "Swift",
            "bookmarkState": [
                "bookmarks": [valid, missingLine, nonPositiveLine, stringLine, nonStringNote]
            ]
        ]

        let restored = DocumentModel.fromSessionData(partial)

        XCTAssertEqual(restored?.bookmarkState.count, 1)
        XCTAssertEqual(restored?.bookmarkState.lines, [2])
        XCTAssertEqual(restored?.bookmarkState.note(forLine: 2), "kept")
    }

    func testBookmarkStateIsIndependentPerDocumentAndSurvivesTabStoreRoundTrip() {
        let first = DocumentModel(text: "first\nsecond\nthird")
        let second = DocumentModel(text: "alpha\nbeta\ngamma\ndelta")
        var firstState = BookmarkState()
        firstState.add(line: 1, note: "first tab")
        firstState.add(line: 3)
        var secondState = BookmarkState()
        secondState.add(line: 4, note: "second tab")
        first.bookmarkState = firstState
        second.bookmarkState = secondState

        XCTAssertNotEqual(first.bookmarkState, second.bookmarkState)

        let store = TabStore()
        store.addDocument(first)
        store.addDocument(second)
        let restored = TabStore.fromSessionData(store.toSessionData())

        XCTAssertEqual(restored.documents.count, 2)
        XCTAssertEqual(restored.documents[0].bookmarkState, firstState)
        XCTAssertEqual(restored.documents[0].bookmarkState.lines, [1, 3])
        XCTAssertEqual(restored.documents[0].bookmarkState.note(forLine: 1), "first tab")
        XCTAssertEqual(restored.documents[1].bookmarkState, secondState)
        XCTAssertEqual(restored.documents[1].bookmarkState.lines, [4])
        XCTAssertEqual(restored.documents[1].bookmarkState.note(forLine: 4), "second tab")
    }
}
