import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P16d-2: File > Save Session… / Load Session….
///
/// The panels are the only untested seams. Menu wiring and validation are
/// checked through HexpadAppDelegate, and the URL-driven cores
/// `saveSessionFile(to:)` / `loadSessionFile(from:)` are driven directly.
/// Load replaces the focused workspace (the startup-restore semantic), so a
/// saved session's documents and selection must land in the same store.
final class SessionMenuTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-session-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = directory
        SessionStore.cancelScheduledSave()
    }

    override func tearDownWithError() throws {
        SessionStore.cancelScheduledSave()
        SessionStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    /// Writes an explicit session file with the same Snapshot the app saves.
    private func writeSession(named name: String,
                              documents: [(text: String, file: URL?)],
                              selected: Int) throws -> URL {
        let store = TabStore()
        for item in documents {
            let doc = item.file.map { DocumentModel(text: item.text, filePath: $0) }
                ?? DocumentModel(text: item.text)
            store.addDocument(doc)
        }
        store.selectedIndex = selected
        let url = directory.appendingPathComponent(name)
        try SessionStore.saveSnapshot(SessionStore.Snapshot.make(from: store), to: url)
        return url
    }

    // MARK: - Menu wiring

    func testFileMenuHasSessionItemsInTheSaveGroup() throws {
        let delegate = HexpadAppDelegate()
        let menu = delegate.makeFileMenu()
        let titles = menu.items.map(\.title)

        let saveAll = try XCTUnwrap(titles.firstIndex(of: "Save All"))
        let closeTab = try XCTUnwrap(titles.firstIndex(of: "Close Tab"))
        for title in ["Save Session…", "Load Session…"] {
            let index = try XCTUnwrap(titles.firstIndex(of: title), "\(title) is in the File menu")
            XCTAssertGreaterThan(index, saveAll, "\(title) sits after the Save group")
            XCTAssertLessThan(index, closeTab, "\(title) sits before the Close group")
        }

        let saveItem = try XCTUnwrap(menu.item(withTitle: "Save Session…"))
        XCTAssertEqual(saveItem.action, #selector(HexpadAppDelegate.saveSessionAs(_:)))
        XCTAssertTrue(saveItem.target === delegate)
        XCTAssertEqual(saveItem.keyEquivalent, "")

        let loadItem = try XCTUnwrap(menu.item(withTitle: "Load Session…"))
        XCTAssertEqual(loadItem.action, #selector(HexpadAppDelegate.loadSession(_:)))
        XCTAssertTrue(loadItem.target === delegate)
        XCTAssertEqual(loadItem.keyEquivalent, "")
    }

    // MARK: - Validation

    func testSaveSessionNeedsATabButLoadSessionIsAlwaysEnabled() throws {
        let delegate = HexpadAppDelegate()
        let controller = makeController()
        delegate.activeControllerOverride = controller

        let saveItem = NSMenuItem(title: "Save Session…",
                                  action: #selector(HexpadAppDelegate.saveSessionAs(_:)),
                                  keyEquivalent: "")
        let loadItem = NSMenuItem(title: "Load Session…",
                                  action: #selector(HexpadAppDelegate.loadSession(_:)),
                                  keyEquivalent: "")

        controller.tabStore.documents = []
        controller.tabStore.selectedIndex = 0
        XCTAssertFalse(delegate.validateMenuItem(saveItem), "nothing to save")
        XCTAssertTrue(delegate.validateMenuItem(loadItem), "Load replaces even an empty workspace")

        controller.tabStore.documents = [DocumentModel(text: "one")]
        controller.tabStore.selectedIndex = 0
        XCTAssertTrue(delegate.validateMenuItem(saveItem))
        XCTAssertTrue(delegate.validateMenuItem(loadItem))
    }

    // MARK: - URL-driven cores

    func testSaveSessionFileWritesALoadableSnapshot() throws {
        let controller = makeController()
        controller.tabStore.documents = [DocumentModel(text: "first"),
                                         DocumentModel(text: "second")]
        controller.tabStore.selectedIndex = 1

        let url = directory.appendingPathComponent("saved.session")
        controller.saveSessionFile(to: url)

        let snapshot = try SessionStore.loadSnapshot(from: url)
        XCTAssertEqual(snapshot.tabs.count, 2)
        XCTAssertEqual(snapshot.selectedIndex, 1)
    }

    func testLoadSessionFileReplacesTheStoreAndRestoresSelection() throws {
        let fileA = directory.appendingPathComponent("a.txt")
        try "a\n".write(to: fileA, atomically: true, encoding: .utf8)
        let url = try writeSession(named: "three.session",
                                   documents: [(text: "a\n", file: fileA),
                                               (text: "draft", file: nil),
                                               (text: "third", file: nil)],
                                   selected: 2)

        let controller = makeController()
        let original = try XCTUnwrap(controller.tabStore.selectedDocument)
        controller.tabStore.documents = [original]
        controller.tabStore.selectedIndex = 0
        XCTAssertEqual(controller.tabStore.count, 1)

        controller.loadSessionFile(from: url)

        XCTAssertEqual(controller.tabStore.count, 3, "the workspace is replaced, not appended")
        XCTAssertFalse(controller.tabStore.documents.contains { $0 === original },
                       "the old tab is gone")
        XCTAssertEqual(controller.tabStore.documents.map(\.text), ["a\n", "draft", "third"])
        XCTAssertEqual(controller.tabStore.selectedIndex, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === controller.tabStore.documents[2])
        XCTAssertEqual(controller.editorTextView?.string, "third",
                       "the editor rebound to the restored selection")
    }
}
