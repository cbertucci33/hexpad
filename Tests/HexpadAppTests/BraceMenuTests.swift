import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// S18f: Search > Go to Matching Brace / Select All In-between. Structure and
/// targets are inspected on the real app menu tree; validation and the two
/// editor actions are driven through a real `MainWindowController` like
/// `TabContextMenuTests` and `MenuWiringTests` do.
final class BraceMenuTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Menu tests must not read the developer's real keybindings.json.
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-brace-menu-tests-\(UUID().uuidString)")
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

    private func searchMenu() throws -> NSMenu {
        let mainMenu = HexpadAppDelegate().buildMainMenu()
        return try XCTUnwrap(mainMenu.item(withTitle: "Search")?.submenu)
    }

    // MARK: - Structure

    func testSearchMenuHasBraceItemsWithExpectedWiring() throws {
        let menu = try searchMenu()
        let go = try XCTUnwrap(menu.item(withTitle: "Go to Matching Brace"))
        let inner = try XCTUnwrap(menu.item(withTitle: "Select All In-between"))

        XCTAssertEqual(go.action, #selector(MainWindowController.goToMatchingBrace(_:)))
        XCTAssertEqual(inner.action, #selector(MainWindowController.selectAllInBetweenBraces(_:)))
        XCTAssertNil(go.target, "brace navigation resolves through the responder chain")
        XCTAssertNil(inner.target)
        XCTAssertEqual(go.keyEquivalent, "", "no invented chord for Go to Matching Brace")
        XCTAssertEqual(inner.keyEquivalent, "", "no invented chord for Select All In-between")

        // Grouped with the other Search navigation commands, in menu order.
        let titles = menu.items.map(\.title)
        let previousResult = try XCTUnwrap(titles.firstIndex(of: "Previous Result"))
        let goIndex = try XCTUnwrap(titles.firstIndex(of: "Go to Matching Brace"))
        let innerIndex = try XCTUnwrap(titles.firstIndex(of: "Select All In-between"))
        XCTAssertLessThan(previousResult, goIndex)
        XCTAssertEqual(innerIndex, goIndex + 1)
    }

    // MARK: - Validation

    func testBraceItemsValidateAgainstFocusedBuffer() throws {
        let controller = makeController()
        let menu = try searchMenu()
        let go = try XCTUnwrap(menu.item(withTitle: "Go to Matching Brace"))
        let inner = try XCTUnwrap(menu.item(withTitle: "Select All In-between"))

        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertFalse(controller.validateMenuItem(go), "empty buffer has no bracket to match")
        XCTAssertFalse(controller.validateMenuItem(inner))

        document.replaceAllText(with: "{ value }")
        XCTAssertTrue(controller.validateMenuItem(go))
        XCTAssertTrue(controller.validateMenuItem(inner))

        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(go), "no focused buffer")
        XCTAssertFalse(controller.validateMenuItem(inner))
    }

    // MARK: - Actions

    func testActionsSelectMatchedBracketAndTheTextBetween() throws {
        let controller = makeController()
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        document.replaceAllText(with: "{ body }") // 0 '{' ... 7 '}'
        document.setLanguage(Language.swift.rawValue)
        controller.updateEditor()

        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        controller.goToMatchingBrace(nil)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 1),
                       "the matched closing brace is selected")

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        controller.selectAllInBetweenBraces(nil)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 6),
                       "only the text between the braces is selected")
    }
}
