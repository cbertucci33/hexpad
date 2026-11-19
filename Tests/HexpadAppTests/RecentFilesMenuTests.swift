import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P16f: File > Open All Recent Files — menu wiring plus the open-all path
/// with a fixture recents list. Verifies the sibling commands Restore Recent
/// Closed File and Empty Recent Files List work too. Mirrors the harness of
/// the other recent-files tests (MacroUITests); recents come from
/// `SessionStore` through a fresh delegate, like a relaunch.
final class RecentFilesMenuTests: XCTestCase {

    private var directory: URL!
    private var window: MainWindow!
    private var controller: MainWindowController!
    private var delegate: HexpadAppDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-recent-files-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = directory

        window = MainWindow()
        controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab

        delegate = HexpadAppDelegate()
        delegate.activeControllerOverride = controller
    }

    override func tearDownWithError() throws {
        SessionStore.overrideDirectory = nil
        window = nil
        controller = nil
        delegate = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func writeFixtureFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A fresh delegate re-reads the fixture recents (its manager is built at
    /// init, mirroring what a relaunch does).
    private func freshDelegate() -> HexpadAppDelegate {
        let fresh = HexpadAppDelegate()
        fresh.activeControllerOverride = controller
        return fresh
    }

    // MARK: - Tests

    func testOpenAllRecentFilesMenuWiring() throws {
        let openRecent = try XCTUnwrap(delegate.makeFileMenu().item(withTitle: "Open Recent")?.submenu)
        let openAll = try XCTUnwrap(openRecent.item(withTitle: "Open All Recent Files"))
        XCTAssertEqual(openAll.action, #selector(HexpadAppDelegate.openAllRecentFiles))
        XCTAssertTrue(openAll.target is HexpadAppDelegate)
        XCTAssertEqual(openRecent.items.suffix(3).map(\.title),
                       ["Restore Recent Closed File", "Open All Recent Files", "Empty Recent Files List"])
    }

    func testOpenAllRecentFilesOpensEveryFixtureRecent() throws {
        let a = try writeFixtureFile("a.txt", contents: "A")
        let b = try writeFixtureFile("b.txt", contents: "B")
        try SessionStore.saveRecents([a.path, b.path])

        let fresh = freshDelegate()
        let before = controller.tabStore.count
        fresh.openAllRecentFiles()

        XCTAssertEqual(controller.tabStore.count, before + 2)
        XCTAssertTrue(controller.tabStore.documents.contains { $0.filePath?.path == a.path })
        XCTAssertTrue(controller.tabStore.documents.contains { $0.filePath?.path == b.path })
    }

    func testRestoreRecentClosedFileReopensNewestClosed() throws {
        let a = try writeFixtureFile("a.txt", contents: "A")
        let b = try writeFixtureFile("b.txt", contents: "B")
        try SessionStore.saveRecents([a.path, b.path])

        let fresh = freshDelegate()
        fresh.restoreRecentClosedFile()

        // Recents are newest-first and nothing is open, so the newest entry
        // `a` is reopened.
        XCTAssertTrue(controller.tabStore.documents.contains { $0.filePath?.path == a.path })
    }

    func testEmptyRecentFilesListClearsValidation() throws {
        let a = try writeFixtureFile("a.txt", contents: "A")
        try SessionStore.saveRecents([a.path])
        let fresh = freshDelegate()

        let openRecent = try XCTUnwrap(delegate.makeFileMenu().item(withTitle: "Open Recent")?.submenu)
        let openAll = try XCTUnwrap(openRecent.item(withTitle: "Open All Recent Files"))
        XCTAssertTrue(fresh.validateMenuItem(openAll), "the list is non-empty")

        fresh.emptyRecentFilesList()
        XCTAssertFalse(fresh.validateMenuItem(openAll), "the list is empty now")
    }
}
