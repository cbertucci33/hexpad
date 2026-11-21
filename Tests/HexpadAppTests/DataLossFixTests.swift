import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

final class DataLossFixTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-data-loss-fix-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeController(resolver: ((DocumentModel) -> ExternalChangeResolution)? = nil) -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        controller.externalChangeResolver = resolver
        return controller
    }

    private func select(_ documents: [DocumentModel],
                        selected: Int = 0,
                        in controller: MainWindowController) {
        controller.tabStore.documents = documents
        controller.tabStore.selectedIndex = selected
    }

    // MARK: - FIX 1 quit resolution

    func testQuitResolutionNoDirtyTerminates() {
        XCTAssertEqual(HexpadAppDelegate.quitResolution(dirtyCount: 0,
                                                      response: .alertThirdButtonReturn),
                       .terminateNow)
    }

    func testQuitResolutionSaveAllTerminates() {
        XCTAssertEqual(HexpadAppDelegate.quitResolution(dirtyCount: 2,
                                                      response: .alertFirstButtonReturn),
                       .terminateNow)
    }

    func testQuitResolutionDontSaveTerminates() {
        XCTAssertEqual(HexpadAppDelegate.quitResolution(dirtyCount: 2,
                                                      response: .alertSecondButtonReturn),
                       .terminateNow)
    }

    func testQuitResolutionCancelAborts() {
        XCTAssertEqual(HexpadAppDelegate.quitResolution(dirtyCount: 2,
                                                      response: .alertThirdButtonReturn),
                       .terminateCancel)
    }

    // MARK: - FIX 4 recents pinning

    func testRecentFilesManagerKeepsOpenFileInList() {
        let manager = RecentFilesManager()
        let path = directory.appendingPathComponent("open.txt").path
        manager.addRecent(path)
        XCTAssertTrue(manager.recents.contains(path),
                      "a recently-opened (still-open) file stays in the list")
    }

    // MARK: - FIX 5 reload preserves bookmarks

    func testReloadTextPreservesBookmarks() {
        let doc = DocumentModel(text: "line one\nline two\n")
        doc.bookmarkState.add(line: 2, note: "keep")
        let originalBookmarkCount = doc.bookmarkState.count
        doc.reloadText("completely different\ncontent\n")
        XCTAssertEqual(doc.bookmarkState.count, originalBookmarkCount)
        XCTAssertTrue(doc.bookmarkState.isBookmarked(line: 2))
    }

    // MARK: - FIX 3 Save All untitled URL core

    func testSaveAllUntitledURLCoreSavesAndClearsDirty() throws {
        let controller = makeController()
        let doc = DocumentModel(text: "scratch edit\n")
        doc.setModified(true)
        select([doc], in: controller)
        XCTAssertTrue(doc.isUntitled)
        XCTAssertTrue(doc.unsavedChanges)

        let url = directory.appendingPathComponent("named.txt")
        XCTAssertTrue(controller.saveDocument(doc, to: url))
        XCTAssertEqual(doc.filePath, url)
        XCTAssertEqual(doc.name, "named.txt")
        XCTAssertFalse(doc.unsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "scratch edit\n")
    }

    func testSaveAllUntitledURLCoreAlias() throws {
        let controller = makeController()
        let doc = DocumentModel(text: "alias\n")
        select([doc], in: controller)
        let url = directory.appendingPathComponent("alias.txt")
        XCTAssertTrue(controller.saveUntitledDocument(doc, to: url))
    }

    // MARK: - FIX 2 close-all failed save abort

    func testSaveDocumentReturnsFalseOnFailure() throws {
        let controller = makeController()
        let blocker = directory.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let doc = DocumentModel(text: "dirty\n",
                                filePath: directory.appendingPathComponent("blocker/child.txt"))
        doc.setModified(true)
        select([doc], in: controller)
        XCTAssertTrue(doc.unsavedChanges)
        XCTAssertFalse(controller.saveDocument(doc))
    }

    // MARK: - Quit Save All aborts on failure

    func testSaveAllDocumentsReturnsFalseOnFailedSave() throws {
        let controller = makeController()
        let blocker = directory.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let doc = DocumentModel(text: "dirty\\n",
                                filePath: directory.appendingPathComponent("blocker/child.txt"))
        doc.setModified(true)
        select([doc], in: controller)
        XCTAssertTrue(doc.unsavedChanges)
        XCTAssertFalse(controller.saveAllDocuments(),
                       "a failed Save All write must report failure")
    }

    func testSaveAllDocumentsReturnsTrueWhenNothingDirty() {
        let controller = makeController()
        let doc = DocumentModel(text: "clean\\n")
        select([doc], in: controller)
        XCTAssertTrue(controller.saveAllDocuments())
    }

    func testQuitResolutionSaveAllFailureAborts() {
        XCTAssertEqual(HexpadAppDelegate.quitResolution(dirtyCount: 2,
                                                       response: .alertFirstButtonReturn,
                                                       saveSucceeded: false),
                       .terminateCancel)
        XCTAssertEqual(HexpadAppDelegate.quitResolution(dirtyCount: 2,
                                                       response: .alertFirstButtonReturn,
                                                       saveAllSucceeded: false),
                       .terminateCancel)
    }
}