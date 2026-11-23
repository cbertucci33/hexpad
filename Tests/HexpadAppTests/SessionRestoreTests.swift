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

    private func toolsMenuItem(titled title: String) throws -> NSMenuItem {
        let menu = HexpadAppDelegate().buildMainMenu()
        let tools = try XCTUnwrap(menu.item(withTitle: "Tools")?.submenu)
        return try XCTUnwrap(tools.items.first { $0.title == title })
    }

    /// Sends the item's own action through NSApplication, exactly as a menu
    /// click does, instead of calling `toggleFileMonitoring` directly.
    @discardableResult
    private func dispatchMenuAction(_ item: NSMenuItem,
                                    to controller: MainWindowController) -> Bool {
        guard let action = item.action else { return false }
        return NSApp.sendAction(action, to: controller, from: item)
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

    // MARK: - V19g: Monitoring mode (tail -f)

    /// Tail mode owns external changes: a dirty buffer follows the file instead
    /// of raising the save-time conflict alert.
    func testTailMonitoringAutoReloadsDirtyBufferAndSuppressesPrompt() throws {
        let file = testDir.appendingPathComponent("tail-dirty-\(UUID().uuidString).txt")
        try "original line\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        controller.setFileMonitoring(true, for: doc)
        doc.text = "local edit\n"
        XCTAssertTrue(doc.unsavedChanges)

        try "external line\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "external line\n", "tail mode follows the file even while dirty")
        XCTAssertFalse(doc.unsavedChanges, "the reload is the clean baseline")
        XCTAssertFalse(doc.hasExternalChange, "tail mode never leaves a pending conflict")

        var prompted = false
        controller.externalChangeResolver = { _ in
            prompted = true
            return .cancel
        }
        doc.noteExternalChange()
        let resolution = controller.externalChangeResolution(for: doc)
        XCTAssertFalse(prompted, "the changed-on-disk alert is suppressed while tailing")
        if case .saveAnyway = resolution {} else {
            XCTFail("tail mode should bypass the prompt, got \(resolution)")
        }
    }

    /// P-10: a tailed log is replaced on every append; each reload must not
    /// push a whole-buffer undo entry (memory would grow with file size ×
    /// appends). An explicit File > Reload stays undoable.
    func testTailReloadsDoNotGrowTheUndoStackButExplicitReloadDoes() throws {
        let file = testDir.appendingPathComponent("tail-undo-\(UUID().uuidString).txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        controller.setFileMonitoring(true, for: doc)
        XCTAssertFalse(doc.undoManager.canUndo)

        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "one\ntwo\n")
        XCTAssertFalse(doc.undoManager.canUndo,
                       "tail appends must not retain full-buffer undo entries")

        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: file.path
        )
        controller.reloadActiveDocument(nil)

        XCTAssertEqual(doc.text, "one\ntwo\nthree\n")
        XCTAssertTrue(doc.undoManager.canUndo, "File > Reload stays one undo step")
    }

    /// P-09: a tail append shares the editor's storage, so it must not run a
    /// forced same-document rebind (fold/bookmark/hidden-line rebuilds plus an
    /// editor-state capture/apply) on every 0.5 s tick. `bookmarkBindCount` is
    /// the container's "full bookmark-model build" hook.
    func testTailAppendDoesNotRebindTheVisibleEditor() throws {
        let file = testDir.appendingPathComponent("tail-rebind-\(UUID().uuidString).txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let editor = try XCTUnwrap(controller.editorContainer)
        controller.setFileMonitoring(true, for: doc)
        let builds = editor.bookmarkBindCount

        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "one\ntwo\n")
        XCTAssertEqual(editor.bookmarkBindCount, builds,
                       "a tail append must not force a same-document rebind")
    }

    /// Turning tail mode on records the current mtime, so an edit that landed
    /// before the toggle is not replayed as if it arrived while watching.
    func testEnablingTailMonitoringRecordsFreshBaseline() throws {
        let file = testDir.appendingPathComponent("tail-baseline-\(UUID().uuidString).txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        try "arrived before monitoring\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.setFileMonitoring(true, for: doc)
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "before\n", "the enabling baseline absorbs the earlier edit")
    }

    /// A caret parked at the old end follows appended text; a caret elsewhere
    /// is left alone even though the viewport may be bottom-pinned.
    func testTailMonitoringFollowsEndOnlyWhenCaretWasAtTheEnd() throws {
        let file = testDir.appendingPathComponent("tail-follow-\(UUID().uuidString).txt")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        controller.setFileMonitoring(true, for: doc)

        // Bottom-pinned caret: it should move to the new end after the append.
        let oldLength = (doc.text as NSString).length
        textView.setSelectedRange(NSRange(location: oldLength, length: 0))
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()
        XCTAssertEqual(doc.text, "one\ntwo\nthree\n")
        XCTAssertEqual(textView.selectedRange.location, (doc.text as NSString).length)

        // Caret moved back into the buffer: the next append must not move it.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()
        XCTAssertEqual(doc.text, "one\ntwo\nthree\nfour\n")
        XCTAssertEqual(textView.selectedRange.location, 0, "a caret away from the tail stays put")
    }

    /// P-13: Tools > Monitor File must work through its real menu dispatch.
    /// Calling `setFileMonitoring` directly (as the older tests do) cannot catch
    /// a nil-targeted item wired to the wrong selector or a validation branch
    /// that never draws the checkmark.
    func testMonitorFileMenuActionTogglesTailStateAndCheckmark() throws {
        let file = testDir.appendingPathComponent("monitor-menu-\(UUID().uuidString).txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let item = try toolsMenuItem(titled: "Monitor File")

        XCTAssertFalse(controller.isFileMonitoring(doc))
        XCTAssertTrue(controller.validateMenuItem(item),
                      "a file-backed document makes the toggle available")
        XCTAssertEqual(item.state, .off)

        XCTAssertTrue(dispatchMenuAction(item, to: controller))
        XCTAssertTrue(controller.isFileMonitoring(doc),
                      "the menu action enables tail-follow")
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on, "the checkmark follows the document's tail state")

        XCTAssertTrue(dispatchMenuAction(item, to: controller))
        XCTAssertFalse(controller.isFileMonitoring(doc),
                       "dispatching again turns tail-follow off")
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    /// P-14: the viewport-pinned half of the tail rule. A tall buffer scrolled
    /// up must not be treated as bottom-pinned, so an append leaves the clip
    /// where the user put it. The old rule compared `textView.frame.maxY` with
    /// the clip height; with the editor's `.height` autoresizing mask that frame
    /// could collapse to the viewport and every viewport looked pinned.
    func testTailAppendDoesNotScrollAScrolledUpViewport() throws {
        let file = testDir.appendingPathComponent("tail-scrollback-\(UUID().uuidString).txt")
        let original = String(repeating: "line\n", count: 2_000)
        try original.write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let editor = try XCTUnwrap(controller.editorContainer)
        let textView = try XCTUnwrap(controller.editorTextView)

        // Give the editor a real viewport and force a full layout so the clip
        // view can actually scroll through the tall buffer.
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        editor.layout()
        editor.textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))
        let clip = editor.scrollView.contentView
        clip.scroll(to: CGPoint(x: 0, y: 240))
        editor.scrollView.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.y, 240, accuracy: 1,
                       "fixture must actually be scrolled into the buffer")

        XCTAssertFalse(controller.isViewportAtDocumentEnd(doc),
                       "a scrolled-up viewport is not pinned to the document end")

        controller.setFileMonitoring(true, for: doc)
        try (original + "appended\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, original + "appended\n")
        XCTAssertFalse(controller.isViewportAtDocumentEnd(doc))
        XCTAssertEqual(clip.bounds.origin.y, 240, accuracy: 1,
                       "a tail append must not yank a user reading scrollback to the end")
    }

    /// P-15: cadence is 0.5 s while any document is tailed and 2.0 s otherwise;
    /// closing the last tailed document restores the slower poll.
    func testWatchCadenceFollowsTailedDocumentsAndRestoresOnLastClose() throws {
        let fileA = testDir.appendingPathComponent("cadence-a-\(UUID().uuidString).txt")
        let fileB = testDir.appendingPathComponent("cadence-b-\(UUID().uuidString).txt")
        try "a\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "b\n".write(to: fileB, atomically: true, encoding: .utf8)

        let (controller, _) = makeController()
        controller.openFile(atPath: fileA.path)
        let docA = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertEqual(controller.currentWatchInterval(), 2.0, accuracy: 0.0001,
                       "no tailed document keeps the ordinary watcher cadence")

        controller.setFileMonitoring(true, for: docA)
        XCTAssertEqual(controller.currentWatchInterval(), 0.5, accuracy: 0.0001,
                       "tail mode shortens the poll for live appends")

        controller.openFile(atPath: fileB.path)
        let docB = try XCTUnwrap(controller.tabStore.selectedDocument)
        controller.setFileMonitoring(true, for: docB)
        XCTAssertEqual(controller.currentWatchInterval(), 0.5, accuracy: 0.0001,
                       "two tailed documents still use the short cadence")

        controller.closeDocument(docA)
        XCTAssertEqual(controller.currentWatchInterval(), 0.5, accuracy: 0.0001,
                       "one remaining tailed document keeps the short cadence")

        controller.closeDocument(docB)
        XCTAssertFalse(controller.isFileMonitoring(docA))
        XCTAssertFalse(controller.isFileMonitoring(docB))
        XCTAssertEqual(controller.currentWatchInterval(), 2.0, accuracy: 0.0001,
                       "closing the last tailed document restores the ordinary cadence")
    }

    /// P-02: a non-empty selection is part of the parked state. The old
    /// restore path only handled zero-length carets, so every append collapsed
    /// the selection to the new end.
    func testTailMonitoringPreservesNonEmptySelectionThroughAppend() throws {
        let file = testDir.appendingPathComponent("tail-selection-\(UUID().uuidString).txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        controller.setFileMonitoring(true, for: doc)
        let selection = NSRange(location: 4, length: 3) // "two"
        textView.setSelectedRange(selection)

        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "one\ntwo\nthree\nfour\n")
        XCTAssertEqual(textView.selectedRange, selection,
                       "a non-empty selection must survive the tail reload")
    }

    /// P-04: log rotation can shrink a tailed file under a parked caret. The
    /// restore path must clamp into the new buffer instead of handing AppKit an
    /// out-of-range selection (NSRangeException).
    func testTailMonitoringClampsCaretWhenFileShrinks() throws {
        let file = testDir.appendingPathComponent("tail-shrink-\(UUID().uuidString).txt")
        try String(repeating: "0123456789", count: 300)
            .write(to: file, atomically: true, encoding: .utf8)
        let (controller, _) = makeController()
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        controller.setFileMonitoring(true, for: doc)
        textView.setSelectedRange(NSRange(location: 1500, length: 0))

        try "short\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 30)],
            ofItemAtPath: file.path
        )
        controller.checkExternalChanges()

        XCTAssertEqual(doc.text, "short\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0),
                       "the parked caret clamps to the shrunken buffer")
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

        // The notice every save/command/conversion path posts. The snapshot
        // build is debounced, but the pending state is marked immediately so
        // callers can still observe a write is coming.
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

    // MARK: - D2: lazy session restore

    /// PERF D2: startup restore must materialize the selected tab and nothing
    /// else. Every restored tab already has its metadata (name, path, dirty
    /// flag, order), which is all the tab bar and `restorableDocuments` read.
    func testStartupRestoreMaterializesOnlyTheSelectedTab() throws {
        let store = TabStore()
        for index in 0..<5 {
            store.addDocument(DocumentModel(text: "tab \(index)\n"))
        }
        store.selectDocument(at: 3)
        try SessionStore.save(store)

        let (controller, _) = makeController()
        let delegate = HexpadAppDelegate()
        delegate.restoreSessionForTest(into: controller)

        XCTAssertEqual(controller.tabStore.count, 5, "order and count survive the restore")
        XCTAssertEqual(controller.tabStore.selectedIndex, 3)
        let documents = controller.tabStore.documents
        XCTAssertTrue(documents[3].isContentLoaded,
                      "the selected tab must be ready for the first frame")
        for index in [0, 1, 2, 4] {
            XCTAssertFalse(documents[index].isContentLoaded,
                           "tab \(index) must wait until it is first displayed")
        }

        // Displaying another tab materializes exactly that tab.
        controller.selectTab(at: 1)
        XCTAssertTrue(documents[1].isContentLoaded)
        XCTAssertFalse(documents[0].isContentLoaded,
                       "a tab switch must not materialize unrelated tabs")
        XCTAssertEqual(documents[1].text, "tab 1\n")
        XCTAssertEqual(controller.editorTextView?.string, "tab 1\n")
    }
}
