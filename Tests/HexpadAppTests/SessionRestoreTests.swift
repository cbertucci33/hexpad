import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Fresh-eyes P2-9/P2-10 coverage: BOM-free buffers for UTF-16 files, the
/// external-change watcher's dirty-buffer path, and the session restore filter
/// for tabs whose file has disappeared.
final class SessionRestoreTests: XCTestCase {

    private var testDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-session-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = testDir
        SessionStore.debounceInterval = 2.0
    }

    override func tearDownWithError() throws {
        SessionStore.cancelScheduledSave()
        SessionStore.overrideDirectory = nil
        if let testDir {
            try? FileManager.default.removeItem(at: testDir)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func utf16LEFile(named name: String, text: String) throws -> URL {
        let url = testDir.appendingPathComponent("\(name)-\(UUID().uuidString).txt")
        let body = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        try (Data([0xFF, 0xFE]) + body).write(to: url)
        return url
    }

    // MARK: - P2-9: BOM handling on open/save

    func testUTF16LEFileWithBOMOpensAtFirstRealCharacterAndSavesBOMBack() throws {
        let text = "hello"
        let file = try utf16LEFile(named: "open-bom", text: text)
        let (controller, _) = makeController()

        controller.openFile(atPath: file.path)

        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertEqual(doc.text, text, "the buffer must start at the first real character")
        XCTAssertFalse(doc.text.hasPrefix("\u{FEFF}"), "no stray BOM in the buffer")
        XCTAssertEqual(doc.encoding, "UTF-16LE")
        XCTAssertTrue(doc.keepsBOM, "the BOM is remembered for the next save")

        doc.text = "hello world"
        try doc.save()

        let saved = try Data(contentsOf: file)
        XCTAssertTrue(saved.starts(with: Data([0xFF, 0xFE])), "the BOM must survive the save")
        XCTAssertEqual(String(data: EncodingDetective.strippingBOM(from: saved),
                              encoding: .utf16LittleEndian),
                       "hello world")
    }

    // MARK: - P2-8: external-change watcher

    func testExternalChangeToDirtyBufferKeepsEditsAndFlagsConflict() throws {
        let file = try utf16LEFile(named: "dirty-external", text: "original line\n")
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)

        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "local edit\n"

        // First pass records the watcher's mtime baseline.
        controller.checkExternalChanges()

        let external = try XCTUnwrap("external line\n".data(using: .utf16LittleEndian))
        try (Data([0xFF, 0xFE]) + external).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )

        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "local edit\n", "the user's buffer must not be overwritten")
        XCTAssertTrue(doc.unsavedChanges)
        XCTAssertTrue(doc.hasExternalChange, "the conflict must be recorded, not silently dropped")
    }

    func testExternalChangeToCleanBufferReloadsAndStaysClean() throws {
        let file = try utf16LEFile(named: "clean-external", text: "original line\n")
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)

        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        controller.checkExternalChanges()

        let external = try XCTUnwrap("external line\n".data(using: .utf16LittleEndian))
        try (Data([0xFF, 0xFE]) + external).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )

        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "external line\n", "a clean buffer follows the file on disk")
        XCTAssertFalse(doc.unsavedChanges)
        XCTAssertTrue(doc.keepsBOM, "the reloaded BOM state is recorded")
    }

    // MARK: - P2-10: missing files and session scheduling

    func testMissingFileWithUnsavedChangesIsKeptAsDirtyTab() throws {
        let missingDirtyURL = testDir.appendingPathComponent("gone-\(UUID().uuidString).txt")
        let dirty = DocumentModel(text: "saved text", filePath: missingDirtyURL)
        dirty.text = "unsaved edits"
        XCTAssertTrue(dirty.unsavedChanges)

        // The same document after a session round trip: the baseline is
        // unreadable, so the whole buffer stays unsaved.
        let restoredDirty = try XCTUnwrap(DocumentModel.fromSessionData(dirty.toSessionData()))
        XCTAssertTrue(restoredDirty.unsavedChanges)

        let missingCleanURL = testDir.appendingPathComponent("also-gone-\(UUID().uuidString).txt")
        let clean = DocumentModel(text: "saved text", filePath: missingCleanURL)
        XCTAssertFalse(clean.unsavedChanges)

        let existingURL = testDir.appendingPathComponent("still-here-\(UUID().uuidString).txt")
        try Data("exists".utf8).write(to: existingURL)
        let existing = DocumentModel(text: "exists", filePath: existingURL)

        let untitled = DocumentModel(text: "draft")

        let kept = HexpadAppDelegate.restorableDocuments(
            from: [restoredDirty, clean, existing, untitled]
        )

        XCTAssertEqual(kept.map(\.id), [restoredDirty.id, existing.id, untitled.id])
        XCTAssertNotNil(kept.first?.filePath,
                        "the original path is preserved so Save can re-create the file")
        XCTAssertEqual(kept.first?.text, "unsaved edits")
    }

    func testDocumentChangeNotificationsScheduleASessionWrite() throws {
        let (controller, _) = makeController()
        SessionStore.cancelScheduledSave()
        XCTAssertFalse(SessionStore.hasPendingChanges)

        // The notice every save/command/conversion path posts.
        NotificationCenter.default.post(
            name: NSNotification.Name("DocumentModifiedDidChange"),
            object: nil
        )
        XCTAssertTrue(SessionStore.hasPendingChanges)

        // Typing goes through the model notice republished by textDidChange.
        SessionStore.cancelScheduledSave()
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.insertText("typed", replacementRange: textView.selectedRange)
        XCTAssertTrue(SessionStore.hasPendingChanges)
    }

    // MARK: - R1: Move to Other View into an empty group

    /// Acceptance gate for the split-view crash: inserting the tab selects it
    /// in the receiving store *before* focus moves there. Chrome used to
    /// highlight the new document into the empty pane's unbound storage, which
    /// raised NSRangeException. Binding must land first.
    func testMoveToOtherViewIntoEmptyGroupBindsBeforeHighlighting() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        // Long enough that highlighting it against an empty storage would be a
        // guaranteed out-of-bounds attribute set.
        doc.text = String(repeating: "let value = 1\n", count: 200)

        controller.openSplitView()
        XCTAssertTrue(controller.isSplitViewOpen)
        XCTAssertEqual(controller.tabStore.count, 1, "group 2 starts empty")

        controller.moveToOtherView(nil)

        // The move focuses group 2; its store holds the moved document only if
        // focus followed.
        XCTAssertEqual(controller.tabStore.count, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === doc)

        let textView = try XCTUnwrap(controller.editorTextView)
        XCTAssertTrue(textView.textStorage === doc.textStorage,
                      "the moved document must be bound before focus chrome runs")
        XCTAssertEqual(textView.string, doc.text)
        XCTAssertNotNil(doc.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil),
                        "chrome/highlighting ran against the bound buffer")
    }

    // MARK: - R2: one file, one document across split groups

    func testOpeningFileAlreadyOpenInOtherGroupFocusesExistingTab() throws {
        let file = testDir.appendingPathComponent("shared-\(UUID().uuidString).txt")
        try "shared text\n".write(to: file, atomically: true, encoding: .utf8)

        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let opened = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertEqual(opened.filePath?.path, file.path)

        controller.openSplitView()
        controller.moveToOtherView(nil)
        XCTAssertEqual(controller.tabStore.count, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === opened)

        // Focus group 1, which holds only the original untitled tab.
        controller.focusGroup(.primary)
        XCTAssertEqual(controller.tabStore.count, 1)
        XCTAssertNil(controller.tabStore.selectedDocument?.filePath)

        controller.openFile(atPath: file.path)

        // Dedupe found the tab in group 2: no second DocumentModel for the same
        // path, and focus followed the existing tab instead of opening here.
        XCTAssertEqual(controller.tabStore.count, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === opened)

        controller.focusGroup(.primary)
        XCTAssertEqual(controller.tabStore.count, 1, "group 1 must not gain a duplicate tab")
        XCTAssertNil(controller.tabStore.selectedDocument?.filePath)
    }

    // MARK: - P16e: Save All

    func testSaveAllSavesDirtyFileBackedDocumentsInBothGroups() throws {
        let primaryURL = testDir.appendingPathComponent("save-all-primary.txt")
        let secondaryURL = testDir.appendingPathComponent("save-all-secondary.txt")
        try "original\n".write(to: primaryURL, atomically: true, encoding: .utf8)
        try "original\n".write(to: secondaryURL, atomically: true, encoding: .utf8)

        let (controller, _) = makeController()
        controller.openSplitView()

        let primaryDoc = DocumentModel(text: "original\n", filePath: primaryURL)
        primaryDoc.text = "primary edit\n"
        let secondaryDoc = DocumentModel(text: "original\n", filePath: secondaryURL)
        secondaryDoc.text = "secondary edit\n"
        // NOTE: Save All now prompts Save As for UNTITLED dirty docs (N++
        // parity, Wave 1 lane 1A) — a modal NSSavePanel, which would hang this
        // headless run, so untitled docs are exercised by the URL-core test in
        // DataLossFixTests instead. This test pins the file-backed sweep only.

        controller.tabStore.documents = [primaryDoc]
        let secondaryStore = try XCTUnwrap(
            controller.allPanes.first { $0.group == .secondary }?.tabStore
        )
        secondaryStore.addDocument(secondaryDoc)

        XCTAssertTrue(primaryDoc.unsavedChanges)
        XCTAssertTrue(secondaryDoc.unsavedChanges)

        controller.saveAllDocuments()

        XCTAssertEqual(try String(contentsOf: primaryURL, encoding: .utf8), "primary edit\n")
        XCTAssertEqual(try String(contentsOf: secondaryURL, encoding: .utf8), "secondary edit\n")
        XCTAssertFalse(primaryDoc.unsavedChanges)
        XCTAssertFalse(secondaryDoc.unsavedChanges)
    }
}
