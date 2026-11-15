import XCTest
@testable import HexpadKit
import Foundation

final class SessionStoreTests: XCTestCase {
    var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HexpadSessionTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        // Isolate from CB's real session file in Application Support.
        SessionStore.overrideDirectory = testDir
    }

    override func tearDown() {
        SessionStore.overrideDirectory = nil
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    func testNoSessionFileReturnsNil() {
        // Fresh temp dir: no session.json exists anywhere SessionStore looks.
        let result = SessionStore.restore()
        XCTAssertNil(result)
    }

    func testSaveAndRestore() throws {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "one"))
        store.addDocument(DocumentModel(text: "two"))
        store.selectDocument(at: 1)

        try SessionStore.save(store)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: testDir.appendingPathComponent("session.json").path))

        let restored = SessionStore.restore()
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.selectedIndex, 1)
        XCTAssertEqual(restored?.tabs.documents.count, 2)
        XCTAssertEqual(restored?.tabs.documents[0].text, "one")
        XCTAssertEqual(restored?.tabs.documents[1].text, "two")
    }

    func testSavePreservesRecentsWrittenSeparately() throws {
        // Regression: save() used to wipe "recents" written by saveRecents().
        let store = TabStore()
        store.addDocument(DocumentModel(text: "only"))
        try SessionStore.save(store)
        try SessionStore.saveRecents(["/tmp/a.hex", "/tmp/b.hex"])
        try SessionStore.save(store)

        XCTAssertEqual(SessionStore.loadRecents(), ["/tmp/a.hex", "/tmp/b.hex"])
        XCTAssertNotNil(SessionStore.restore())
    }

    func testClear() throws {
        let store = TabStore()
        store.addDocument(DocumentModel(text: "x"))
        try SessionStore.save(store)
        XCTAssertNotNil(SessionStore.restore())
        try SessionStore.clear()
        XCTAssertNil(SessionStore.restore())
    }

    // MARK: - Per-tab editor state

    func testPerTabEditorStateSurvivesSaveAndRestore() throws {
        let store = TabStore()

        // Untitled doc: no file path, so its editor state must be carried
        // entirely by the session JSON.
        let draft = DocumentModel()
        draft.text = "draft buffer"
        draft.caretRange = NSRange(location: 6, length: 2)
        draft.scrollOffset = CGPoint(x: 0, y: 120)
        draft.wordWrapEnabled = true
        draft.zoomScale = 1.25
        store.addDocument(draft)

        // Second tab with a deliberately different state; adding it also
        // selects it, so the selected index must round-trip too.
        let second = DocumentModel(text: "second buffer")
        second.caretRange = NSRange(location: 1, length: 0)
        second.scrollOffset = CGPoint(x: 8, y: 15)
        second.wordWrapEnabled = false
        second.zoomScale = 0.75
        store.addDocument(second)

        try SessionStore.save(store)
        let restored = try XCTUnwrap(SessionStore.restore())

        XCTAssertEqual(restored.selectedIndex, 1)
        XCTAssertEqual(restored.tabs.documents.count, 2)

        let restoredDraft = restored.tabs.documents[0]
        XCTAssertTrue(restoredDraft.isUntitled)
        XCTAssertEqual(restoredDraft.text, "draft buffer")
        XCTAssertEqual(restoredDraft.caretRange, NSRange(location: 6, length: 2))
        XCTAssertEqual(restoredDraft.scrollOffset.y, 120, accuracy: 0.0001)
        XCTAssertTrue(restoredDraft.wordWrapEnabled)
        XCTAssertEqual(restoredDraft.zoomScale, 1.25, accuracy: 0.0001)

        let restoredSecond = restored.tabs.documents[1]
        XCTAssertEqual(restoredSecond.caretRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(restoredSecond.scrollOffset, CGPoint(x: 8, y: 15))
        XCTAssertFalse(restoredSecond.wordWrapEnabled)
        XCTAssertEqual(restoredSecond.zoomScale, 0.75, accuracy: 0.0001)
    }

    func testLegacySessionFileWithoutEditorStateRestoresDefaults() throws {
        // A session.json written by an older build: the document dictionaries
        // have no "editorState" (or "foldState") key at all.
        let legacy: [String: Any] = [
            "tabs": [[
                "id": UUID().uuidString,
                "text": "from an old build",
                "name": "Untitled",
                "encoding": "UTF-8",
                "eolType": "LF",
                "language": "Plain Text",
                "isModified": false
            ]],
            "selectedIndex": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: testDir.appendingPathComponent("session.json"))

        let restored = try XCTUnwrap(SessionStore.restore())

        XCTAssertEqual(restored.tabs.documents.count, 1)
        XCTAssertEqual(restored.tabs.documents[0].text, "from an old build")
        XCTAssertEqual(restored.tabs.documents[0].editorState, .default)
        XCTAssertEqual(restored.tabs.documents[0].foldState, FoldState())
        XCTAssertTrue(restored.tabs.documents[0].foldState.isEmpty)
    }

    func testPerTabFoldStateSurvivesSaveAndRestore() throws {
        let store = TabStore()

        let doc = DocumentModel(text: "{\n    // region\n}")
        var state = FoldState()
        state.insert(FoldRange(location: 0,
                               length: (doc.text as NSString).length,
                               kind: .braces))
        state.insert(FoldRange(location: 6, length: 10, kind: .region))
        doc.foldState = state
        store.addDocument(doc)

        // A second tab with no collapsed folds proves the states stay
        // independent through the real JSON file.
        let second = DocumentModel(text: "no folds")
        store.addDocument(second)

        try SessionStore.save(store)
        let restored = try XCTUnwrap(SessionStore.restore())

        XCTAssertEqual(restored.tabs.documents.count, 2)
        XCTAssertEqual(restored.tabs.documents[0].foldState, state)
        XCTAssertEqual(restored.tabs.documents[0].foldState.count, 2)
        XCTAssertTrue(restored.tabs.documents[1].foldState.isEmpty)
    }

    func testPerTabBookmarkStateSurvivesSaveAndRestore() throws {
        let store = TabStore()

        let doc = DocumentModel(text: "one\ntwo\nthree")
        var state = BookmarkState()
        state.add(line: 1, note: "start here")
        state.add(line: 3)
        doc.bookmarkState = state
        store.addDocument(doc)

        // A second tab with no bookmarks proves the states stay independent
        // through the real JSON file.
        let second = DocumentModel(text: "no bookmarks")
        store.addDocument(second)

        try SessionStore.save(store)
        let restored = try XCTUnwrap(SessionStore.restore())

        XCTAssertEqual(restored.tabs.documents.count, 2)
        XCTAssertEqual(restored.tabs.documents[0].bookmarkState, state)
        XCTAssertEqual(restored.tabs.documents[0].bookmarkState.lines, [1, 3])
        XCTAssertEqual(restored.tabs.documents[0].bookmarkState.note(forLine: 1), "start here")
        XCTAssertNil(restored.tabs.documents[0].bookmarkState.note(forLine: 3))
        XCTAssertTrue(restored.tabs.documents[1].bookmarkState.isEmpty)
    }

    // MARK: - P2-7: "Convert to" survives the session

    func testPendingConvertToSurvivesSessionAndNextSaveWritesConvertedBytes() throws {
        let file = testDir.appendingPathComponent("convert-to-\(UUID().uuidString).txt")
        try Data("héllo".utf8).write(to: file)

        let doc = DocumentModel(text: "héllo", filePath: file, encoding: "UTF-8")
        try doc.convertEncoding(to: "UTF-16LE")
        XCTAssertTrue(doc.unsavedChanges)

        let store = TabStore()
        store.addDocument(doc)
        try SessionStore.save(store)

        let restored = try XCTUnwrap(SessionStore.restore()?.tabs.documents.first)

        XCTAssertEqual(restored.encoding, "UTF-8", "Convert to must not change the decode encoding")
        XCTAssertEqual(restored.saveEncoding, "UTF-16LE", "the next save still targets UTF-16LE")
        XCTAssertTrue(restored.hasPendingSaveConversion)
        XCTAssertTrue(restored.unsavedChanges, "a pending conversion must not look clean after restore")

        try restored.save()

        let saved = try Data(contentsOf: file)
        XCTAssertEqual(saved, "héllo".data(using: .utf16LittleEndian),
                       "the next save after a restore must write the converted bytes")
        XCTAssertFalse(restored.unsavedChanges)
        XCTAssertFalse(restored.hasPendingSaveConversion)
    }

    // MARK: - P2-8: dirty state survives for non-UTF-8 files

    func testUTF16DirtyBufferSurvivesSessionWithoutLosingDirtyState() throws {
        let file = testDir.appendingPathComponent("utf16-dirty-\(UUID().uuidString).txt")
        let onDisk = "original line\n"
        let bomData = Data([0xFF, 0xFE])
        let bodyData = try XCTUnwrap(onDisk.data(using: .utf16LittleEndian))
        try (bomData + bodyData).write(to: file)

        // Open the way MainWindowController does: BOM-stripped UTF-16LE.
        let doc = DocumentModel(text: onDisk, filePath: file, encoding: "UTF-16LE")
        doc.keepsBOM = true
        doc.text = "unsaved edit\n"
        XCTAssertTrue(doc.unsavedChanges)

        let store = TabStore()
        store.addDocument(doc)
        try SessionStore.save(store)

        let restored = try XCTUnwrap(SessionStore.restore()?.tabs.documents.first)

        XCTAssertEqual(restored.text, "unsaved edit\n", "the buffer survives")
        XCTAssertEqual(restored.encoding, "UTF-16LE")
        XCTAssertEqual(restored.eolType, doc.eolType)
        // This used to read the baseline as UTF-8, fail, fall back to the
        // buffer text, and report the restored document as clean.
        XCTAssertTrue(restored.unsavedChanges,
                      "a dirty UTF-16 document must not restore as clean")
    }

    func testUTF16CleanBufferRestoresClean() throws {
        let file = testDir.appendingPathComponent("utf16-clean-\(UUID().uuidString).txt")
        let onDisk = "already saved\n"
        let bomData = Data([0xFF, 0xFE])
        let bodyData = try XCTUnwrap(onDisk.data(using: .utf16LittleEndian))
        try (bomData + bodyData).write(to: file)

        let doc = DocumentModel(text: onDisk, filePath: file, encoding: "UTF-16LE")
        doc.keepsBOM = true

        let store = TabStore()
        store.addDocument(doc)
        try SessionStore.save(store)

        let restored = try XCTUnwrap(SessionStore.restore()?.tabs.documents.first)
        XCTAssertFalse(restored.unsavedChanges, "an unchanged UTF-16 buffer restores clean")
        XCTAssertTrue(restored.keepsBOM, "BOM state survives the session")
    }
}
