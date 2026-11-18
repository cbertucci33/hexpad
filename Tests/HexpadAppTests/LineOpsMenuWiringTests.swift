import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// App-side wiring for the P17a Line Operations commands. The Kit tests pin
/// the transforms; these pin the menu/controller path a user actually invokes.
final class LineOpsMenuWiringTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-lineops-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        if let keybindingDirectory {
            try? FileManager.default.removeItem(at: keybindingDirectory)
        }
        try super.tearDownWithError()
    }

    private func lineOpsMenu() throws -> NSMenu {
        let menu = HexpadAppDelegate().buildMainMenu()
        return try XCTUnwrap(menu.item(withTitle: "Line Ops")?.submenu)
    }

    func testLineOpsMenuMirrorsRegistryCommandsInOrder() throws {
        let menu = try lineOpsMenu()
        let commandItems = menu.items.filter {
            $0.action == #selector(MainWindowController.performCommand(withIdentifier:))
        }
        let commands = CommandRegistry.default.lineOpCommands

        XCTAssertEqual(commandItems.map(\.title), commands.map(\.title))
        for (item, command) in zip(commandItems, commands) {
            XCTAssertEqual(item.representedObject as? String, command.identifier)
            XCTAssertNil(item.target, "commands must resolve through the first responder chain")
        }
    }

    func testNewLineOpsAreReachableFromTheMenu() throws {
        let menu = try lineOpsMenu()
        let newIdentifiers = [
            "reverse-line-order",
            "sort-lines-integer-ascending", "sort-lines-integer-descending",
            "sort-lines-decimal-ascending", "sort-lines-decimal-descending",
            "remove-consecutive-duplicate-lines", "remove-empty-lines-with-whitespace",
            "trim-trailing-space", "trim-leading-space", "trim-leading-and-trailing-space"
        ]
        for identifier in newIdentifiers {
            let item = try XCTUnwrap(menu.items.first {
                ($0.representedObject as? String) == identifier
            }, identifier)
            XCTAssertEqual(item.action,
                           #selector(MainWindowController.performCommand(withIdentifier:)),
                           identifier)
        }
    }

    func testPerformCommandRunsANewLineOpThroughTheController() throws {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view

        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        document.replaceAllText(with: "alpha  \nbeta\t")
        document.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "trim-trailing-space"))
        XCTAssertEqual(document.text, "alpha\nbeta")

        document.undoManager.undo()
        XCTAssertEqual(document.text, "alpha  \nbeta\t")
    }
}
