import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P16d-1: File > Move to Trash.
///
/// The NSAlert in `trashSelectedDocument()` is the only untested seam. Every
/// decision it can produce is expressed as a `TrashPromptResolution`, so the
/// `trashDocument(_:resolution:)` core is driven directly here: a clean file is
/// trashed through the public entry point (no prompt), while dirty-document
/// Save / Don't Save / Cancel are injected as values.
final class MoveToTrashTests: XCTestCase {

    private var directory: URL!
    private var trashedNames: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-move-to-trash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        trashedNames = []
    }

    override func tearDownWithError() throws {
        // Trashed files are invisible to the test's temp-directory cleanup, so
        // pick the uniquely named items back out of the user's Trash.
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for name in trashedNames {
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    private func select(_ documents: [DocumentModel],
                        selected: Int = 0,
                        in controller: MainWindowController) {
        controller.tabStore.documents = documents
        controller.tabStore.selectedIndex = selected
    }

    private func makeFile(named name: String, text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        trashedNames.append(name)
        return url
    }

    // MARK: - Validation

    /// N++ grays out Move to Recycle Bin for untitled documents: only a
    /// file-backed focused tab enables the delegate-targeted item.
    func testMoveToTrashValidationRequiresFileBackedDocument() throws {
        let delegate = HexpadAppDelegate()
        let controller = makeController()
        // AppKit has no key window in the test host; inject the delegate's
        // active controller through the same seam used by menu actions.
        delegate.activeControllerOverride = controller

        let item = NSMenuItem(title: "Move to Trash",
                              action: #selector(HexpadAppDelegate.moveToTrash(_:)),
                              keyEquivalent: "")

        let untitled = DocumentModel(text: "draft")
        select([untitled], in: controller)
        XCTAssertTrue(untitled.isUntitled, "fixture is untitled")
        XCTAssertFalse(delegate.validateMenuItem(item),
                       "no backing file => disabled")

        let url = try makeFile(named: "validated.txt", text: "text\n")
        let fileBacked = DocumentModel(text: "text\n", filePath: url)
        select([fileBacked], in: controller)
        XCTAssertTrue(delegate.validateMenuItem(item),
                      "file-backed focused document => enabled")
    }

    // MARK: - Clean document (no prompt)

    func testCleanDocumentIsTrashedAndTabClosed() throws {
        let url = try makeFile(named: "clean.txt", text: "clean line\n")
        let doc = DocumentModel(text: "clean line\n", filePath: url)
        let controller = makeController()
        let other = DocumentModel(text: "stay open\n")
        select([doc, other], in: controller)
        XCTAssertEqual(controller.tabStore.count, 2)

        // Clean documents skip the NSAlert, so the real menu path is testable.
        controller.trashSelectedDocument()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the backing file left its original path")
        XCTAssertEqual(controller.tabStore.count, 1, "only the trashed tab closed")
        XCTAssertFalse(controller.tabStore.documents.contains { $0 === doc })
        XCTAssertTrue(controller.tabStore.documents.contains { $0 === other })
    }

    // MARK: - Dirty document: the injected prompt answers

    func testDirtyDocumentDiscardTrashesAndCloses() throws {
        let saved = "saved line\n"
        let url = try makeFile(named: "dirty-discard.txt", text: saved)
        let doc = DocumentModel(text: saved, filePath: url)
        doc.replaceAllText(with: saved + "unsaved line\n")
        XCTAssertTrue(doc.unsavedChanges, "fixture is dirty")

        let controller = makeController()
        select([doc, DocumentModel(text: "other\n")], in: controller)

        let closed = controller.trashDocument(doc, resolution: .discard)

        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(controller.tabStore.count, 1)
        XCTAssertFalse(controller.tabStore.documents.contains { $0 === doc })
    }

    func testDirtyDocumentCancelKeepsFileAndTab() throws {
        let saved = "saved line\n"
        let url = try makeFile(named: "dirty-cancel.txt", text: saved)
        let doc = DocumentModel(text: saved, filePath: url)
        doc.replaceAllText(with: saved + "unsaved line\n")

        let controller = makeController()
        select([doc, DocumentModel(text: "other\n")], in: controller)

        let closed = controller.trashDocument(doc, resolution: .cancel)

        XCTAssertFalse(closed, "Cancel aborts the whole operation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the file is intact")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), saved,
                       "the unsaved edits were not written to disk")
        XCTAssertEqual(controller.tabStore.count, 2, "the tab stays open")
        XCTAssertTrue(controller.tabStore.documents.contains { $0 === doc })
        XCTAssertTrue(doc.unsavedChanges, "the buffer stays dirty")
    }

    func testDirtyDocumentSaveWritesBeforeTrashing() throws {
        let saved = "saved line\n"
        let url = try makeFile(named: "dirty-save.txt", text: saved)
        let doc = DocumentModel(text: saved, filePath: url)
        let edited = saved + "now saved\n"
        doc.replaceAllText(with: edited)

        let controller = makeController()
        select([doc, DocumentModel(text: "other\n")], in: controller)

        let closed = controller.trashDocument(doc, resolution: .save)

        XCTAssertTrue(closed)
        XCTAssertFalse(doc.unsavedChanges,
                       "Save's setModified(false) proves the write succeeded before trashing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(controller.tabStore.count, 1)
    }

    /// Validation disables the item, but a direct call must still be a no-op
    /// rather than closing an untitled tab.
    func testUntitledDocumentIsANoOp() {
        let controller = makeController()
        let untitled = DocumentModel(text: "draft")
        select([untitled, DocumentModel(text: "other\n")], in: controller)

        let closed = controller.trashDocument(untitled, resolution: .discard)

        XCTAssertFalse(closed)
        XCTAssertEqual(controller.tabStore.count, 2)
        XCTAssertTrue(controller.tabStore.documents.contains { $0 === untitled })
    }

    // MARK: - Menu wiring

    func testFileMenuWiresMoveToTrashInTheCloseGroup() throws {
        let delegate = HexpadAppDelegate()
        let menu = delegate.makeFileMenu()
        let titles = menu.items.map(\.title)

        let bulkClose = try XCTUnwrap(titles.firstIndex(of: "Close Multiple Documents"))
        XCTAssertEqual(titles[bulkClose + 1], "Move to Trash",
                       "it sits with the close items, after the bulk-close submenu")

        let item = try XCTUnwrap(menu.item(withTitle: "Move to Trash"))
        XCTAssertEqual(item.action, #selector(HexpadAppDelegate.moveToTrash(_:)))
        XCTAssertTrue(item.target === delegate)
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
