import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// W23a: Window > Sort By. Structure and target/action wiring are inspected on
/// the real menu tree, validation and the action are driven through a real
/// `MainWindowController`, following `BraceMenuTests` / `TabContextMenuTests`.
final class SortByMenuTests: XCTestCase {
    private var keybindingDirectory: URL!

    private let expectedItems: [(title: String, key: String, tag: Int)] = [
        ("Name (Ascending)", "name", 1),
        ("Name (Descending)", "name", 0),
        ("Path (Ascending)", "path", 1),
        ("Path (Descending)", "path", 0),
        ("Type (Ascending)", "type", 1),
        ("Type (Descending)", "type", 0),
        ("Length (Ascending)", "length", 1),
        ("Length (Descending)", "length", 0),
        ("Modified (Ascending)", "modified", 1),
        ("Modified (Descending)", "modified", 0),
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-sort-by-menu-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        if let keybindingDirectory {
            try? FileManager.default.removeItem(at: keybindingDirectory)
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

    private func windowMenu() throws -> NSMenu {
        let mainMenu = HexpadAppDelegate().buildMainMenu()
        return try XCTUnwrap(mainMenu.item(withTitle: "Window")?.submenu)
    }

    private func sortByMenu() throws -> NSMenu {
        try XCTUnwrap(windowMenu().item(withTitle: "Sort By")?.submenu)
    }

    // MARK: - Structure

    func testSortBySubmenuHasTenItemsInExpectedOrder() throws {
        let menu = try sortByMenu()
        XCTAssertEqual(menu.items.map(\.title), expectedItems.map(\.title))
        XCTAssertEqual(menu.items.count, 10)
    }

    func testSortBySitsAfterTabBlockWithSeparatorBeforeIt() throws {
        let menu = try windowMenu()
        let items = menu.items
        let tabNine = try XCTUnwrap(items.firstIndex { $0.title == "Tab 9" })
        let sortBy = try XCTUnwrap(items.firstIndex { $0.title == "Sort By" })
        XCTAssertLessThan(tabNine, sortBy)
        XCTAssertTrue(items[sortBy - 1].isSeparatorItem)
        XCTAssertNotNil(items[sortBy].submenu)
    }

    func testSortItemsActionTargetAndEncoding() throws {
        let menu = try sortByMenu()
        for (item, expected) in zip(menu.items, expectedItems) {
            XCTAssertEqual(item.action, #selector(MainWindowController.sortDocumentsBy(_:)),
                           "\(expected.title) action")
            XCTAssertNil(item.target, "\(expected.title) resolves through the responder chain")
            XCTAssertEqual(item.keyEquivalent, "", "\(expected.title) has no invented chord")
            XCTAssertEqual(item.representedObject as? String, expected.key,
                           "\(expected.title) key encoding")
            XCTAssertEqual(item.tag, expected.tag,
                           "\(expected.title) direction encoding (1 ascending, 0 descending)")
        }
    }

    // MARK: - Validation

    func testSortItemsValidateAgainstTabCount() throws {
        let controller = makeController()
        let items = try sortByMenu().items
        XCTAssertEqual(controller.tabStore.count, 1)

        for item in items {
            XCTAssertFalse(controller.validateMenuItem(item),
                           "\(item.title) disabled with one tab")
        }

        controller.tabStore.addDocument(DocumentModel(text: "second"))
        for item in items {
            XCTAssertTrue(controller.validateMenuItem(item),
                          "\(item.title) enabled with two tabs")
        }
    }

    // MARK: - Action

    func testSortActionUsesItemEncodingToReorderTabs() throws {
        let controller = makeController()
        let store = controller.tabStore
        store.documents[0].name = "Zebra"
        let alpha = DocumentModel(text: "aaa")
        alpha.name = "Alpha"
        let beta = DocumentModel(text: "a")
        beta.name = "beta"
        store.addDocument(alpha)
        store.addDocument(beta)

        let menu = try sortByMenu()
        let ascending = try XCTUnwrap(menu.item(withTitle: "Name (Ascending)"))
        controller.sortDocumentsBy(ascending)
        XCTAssertEqual(store.documents.map(\.name), ["Alpha", "beta", "Zebra"])

        let descending = try XCTUnwrap(menu.item(withTitle: "Name (Descending)"))
        controller.sortDocumentsBy(descending)
        XCTAssertEqual(store.documents.map(\.name), ["Zebra", "beta", "Alpha"])
    }
}
