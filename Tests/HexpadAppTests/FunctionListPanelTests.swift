import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Wiring coverage for the View > Function List panel. These instantiate the
/// real panel and the real main-window controller, following the existing
/// app-test convention, so the assertions pin the UI contract (population,
/// empty state, navigation, and menu validation) rather than duplicating the
/// Kit model's own tests.
final class FunctionListPanelTests: XCTestCase {

    /// Two methods, both detected by the Swift grammar's "identifier followed
    /// by (" rule. Lines are 2 and 6, which lets the panel test prove that the
    /// line numbers come from `FunctionListModel` unchanged.
    private let swiftSource = """
    struct Greeter {
        func greet(name: String) -> String {
            return "Hello"
        }

        func reset() {
        }
    }
    """

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loads the view and creates the first tab
        return (controller, window)
    }

    // MARK: - Population

    func testPanelPopulatesForSwiftFixture() throws {
        let panel = FunctionListWindowController()
        let document = DocumentModel(text: swiftSource)
        document.setLanguage(Language.swift.rawValue)

        panel.update(document: document)

        XCTAssertEqual(panel.symbols.map(\.name), ["greet", "reset"])
        XCTAssertEqual(panel.symbols.map(\.kind), [.method, .method])
        XCTAssertEqual(panel.symbols.map(\.line), [2, 6])
        XCTAssertFalse(panel.symbols.isEmpty)

        // The panel shows the model's name range untouched, which is what
        // navigation selects.
        let source = swiftSource as NSString
        XCTAssertEqual(panel.symbols[0].range, source.range(of: "greet"))
        XCTAssertEqual(panel.symbols[1].range, source.range(of: "reset"))
    }

    func testPanelIsEmptyForPlainText() throws {
        let panel = FunctionListWindowController()
        let document = DocumentModel(text: "just plain words\nnothing callable here")

        panel.update(document: document)

        XCTAssertTrue(panel.symbols.isEmpty,
                      "Plain Text has no symbol metadata, so the outline is empty")
        XCTAssertEqual(document.language, Language.plain.rawValue)
    }

    func testPanelClearsWhenDocumentGoesAway() throws {
        let panel = FunctionListWindowController()
        let document = DocumentModel(text: swiftSource)
        document.setLanguage(Language.swift.rawValue)
        panel.update(document: document)
        XCTAssertFalse(panel.symbols.isEmpty)

        panel.update(document: nil)
        XCTAssertTrue(panel.symbols.isEmpty)
    }

    // MARK: - Navigation

    func testNavigationSelectsTheSymbolNameRange() throws {
        let (controller, _) = makeController()
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        document.replaceAllText(with: swiftSource)
        document.setLanguage(Language.swift.rawValue)
        controller.updateEditor()

        let panel = FunctionListWindowController()
        panel.onSelectSymbol = { [weak controller] symbol in
            controller?.navigateToSymbol(symbol)
        }
        panel.update(document: document)

        let symbol = try XCTUnwrap(panel.symbols.first)
        XCTAssertEqual(symbol.name, "greet")

        panel.activateRow(0)

        let textView = try XCTUnwrap(controller.editorTextView)
        XCTAssertEqual(textView.selectedRange, symbol.range)
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange),
                       "greet")
    }

    // MARK: - Menu validation

    private func functionListItem() -> NSMenuItem {
        NSMenuItem(title: "Function List",
                   action: #selector(MainWindowController.toggleFunctionList(_:)),
                   keyEquivalent: "")
    }

    func testFunctionListValidationRequiresDocument() throws {
        let (controller, _) = makeController()
        let item = functionListItem()

        XCTAssertTrue(controller.validateMenuItem(item),
                      "the default tab is a document, so the panel is available")

        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(item),
                       "no document means no outline to show")

        XCTAssertFalse(controller.canShowFunctionList())
        // The action must also be a no-op rather than opening an empty panel.
        controller.toggleFunctionList(nil)
        XCTAssertFalse(controller.isFunctionListVisible)
    }

    func testViewMenuExposesFunctionListWithCmdF12() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let item = try XCTUnwrap(viewMenu.item(withTitle: "Function List"))

        XCTAssertEqual(item.keyEquivalent, "\u{F70F}", "F12's AppKit key scalar")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item.action, #selector(MainWindowController.toggleFunctionList(_:)))
        XCTAssertNil(item.target, "validation reaches the main controller through the responder chain")
    }
}
