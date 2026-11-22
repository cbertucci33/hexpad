import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P17f / P17f-2: end-to-end coverage for per-language comment toggling.
///
/// The controller owns one registry for the whole window, so the
/// `toggle-line-comment` prefix must follow the focused document's language
/// (controller setup mirrors `BraceMenuTests`). Comment tokens come from the
/// language's lexer metadata; a language that declares none must disable the
/// item instead of receiving a guessed `//` or `/* */`.
final class CommentCommandTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    /// Sets text and language on the focused document, then rebinds — the same
    /// path `MainWindowController.setLanguage(_:)` takes in the app.
    @discardableResult
    private func useLanguage(_ language: Language,
                             text: String,
                             in controller: MainWindowController) throws -> DocumentModel {
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        document.replaceAllText(with: text)
        document.setLanguage(language.rawValue)
        controller.updateEditor()
        return document
    }

    private func textMenuItem(_ title: String) -> NSMenuItem? {
        HexpadAppDelegate().makeTextMenu().item(withTitle: title)
    }

    private func blockCommentMenuItem(_ delegate: HexpadAppDelegate) -> NSMenuItem? {
        delegate.makeEditMenu()
            .item(withTitle: "Comment/Uncomment")?
            .submenu?
            .item(withTitle: "Block Comment")
    }

    /// Runs the block command the way the Edit menu does: resolve the focused
    /// document's language pair at call time and pass it as the macro-style
    /// parameter. A language without a pair resolves to nil, which the command
    /// treats as a no-op (there is no C-family fallback).
    @discardableResult
    private func performBlockComment(in controller: MainWindowController) -> Bool {
        controller.performCommand(
            identifier: "toggle-block-comment",
            parameter: CommentPrefixResolver.blockCommentParameter(
                for: controller.tabStore.selectedDocument))
    }

    /// Dispatches `item` the way the menu does, through NSApplication and the
    /// item's own target/action, rather than calling the controller method
    /// directly. P-12: a nil-targeted menu item that is mis-wired to the
    /// parameterless command path must fail here.
    @discardableResult
    private func dispatchMenuAction(_ item: NSMenuItem,
                                    to controller: MainWindowController) -> Bool {
        guard let action = item.action else { return false }
        return NSApp.sendAction(action, to: controller, from: item)
    }

    // MARK: - Line comments

    func testPythonDocumentTogglesHashPrefix() throws {
        let controller = makeController()
        let document = try useLanguage(.python, text: "alpha\nbeta", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        // Python's line-prefix metadata is `#` (no trailing space).
        XCTAssertEqual(document.text, "#alpha\nbeta")

        // Toggling again strips it.
        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "alpha\nbeta")
    }

    func testSwiftDocumentTogglesDoubleSlashPrefix() throws {
        let controller = makeController()
        let document = try useLanguage(.swift, text: "alpha\nbeta", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "//alpha\nbeta")
    }

    /// The shared registry must retarget when the same document's language
    /// changes, not only when a new tab is bound.
    func testLanguageChangeRetargetsCommentPrefix() throws {
        let controller = makeController()
        let document = try useLanguage(.python, text: "alpha", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "#alpha")

        try useLanguage(.swift, text: "alpha", in: controller)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "//alpha")
    }

    func testLineCommentPreservesIndentationAndSkipsBlankLines() throws {
        let controller = makeController()
        let original = "  alpha\n\n\tbeta"
        let document = try useLanguage(.python, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "  #alpha\n\n\t#beta",
                       "the token follows each line's indentation; blank lines stay blank")

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, original)
    }

    func testLineCommentIsDisabledForLanguageWithoutLineMetadata() throws {
        let controller = makeController()
        let item = try XCTUnwrap(textMenuItem("Toggle Line Comment"))

        let document = try useLanguage(.html, text: "alpha", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertFalse(controller.validateMenuItem(item),
                       "HTML declares no line comment; the item must be disabled")
        XCTAssertFalse(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "alpha", "no guessed `//` token")

        try useLanguage(.swift, text: "alpha", in: controller)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.validateMenuItem(item), "Swift declares `//`")
    }

    func testLineCommentIsOneUndoGroup() throws {
        let controller = makeController()
        let original = "alpha\nbeta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        document.undoManager.removeAllActions()

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "//alpha\n//beta")

        document.undoManager.undo()
        XCTAssertEqual(document.text, original, "one command must be one undo step")
        XCTAssertFalse(document.undoManager.canUndo)
    }

    // MARK: - Block comments

    func testSwiftDocumentWrapsSelectionWithBlockDelimiters() throws {
        let controller = makeController()
        let original = "alpha\nbeta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        XCTAssertTrue(performBlockComment(in: controller))
        XCTAssertEqual(document.text, "/*alpha\nbeta*/")

        XCTAssertTrue(performBlockComment(in: controller))
        XCTAssertEqual(document.text, original)
    }

    func testHTMLDocumentUsesItsOwnBlockDelimiters() throws {
        let controller = makeController()
        let original = "alpha\nbeta"
        let document = try useLanguage(.html, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        XCTAssertTrue(performBlockComment(in: controller))
        XCTAssertEqual(document.text, "<!--alpha\nbeta-->")
    }

    func testBlockCommentPreservesIndentation() throws {
        let controller = makeController()
        let original = "  alpha\n  beta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        XCTAssertTrue(performBlockComment(in: controller))
        XCTAssertEqual(document.text, "  /*alpha\n  beta*/")
    }

    func testBlockCommentIsDisabledForLanguageWithoutBlockMetadata() throws {
        let controller = makeController()
        let item = try XCTUnwrap(blockCommentMenuItem(HexpadAppDelegate()))

        let document = try useLanguage(.python, text: "alpha", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        XCTAssertFalse(controller.validateMenuItem(item),
                       "Python declares no block pair; the item must be disabled")
        XCTAssertFalse(performBlockComment(in: controller))
        XCTAssertEqual(document.text, "alpha", "no guessed `/* */` delimiters")

        try useLanguage(.swift, text: "alpha", in: controller)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(controller.validateMenuItem(item), "Swift declares `/* */`")

        // The bare identity execute is not a working substitute for the
        // parameterized command: calling it without the language pair must
        // still be a no-op even though Swift has one.
        XCTAssertFalse(controller.performCommand(identifier: "toggle-block-comment"))
        XCTAssertEqual(document.text, "alpha")
        XCTAssertTrue(performBlockComment(in: controller))
        XCTAssertEqual(document.text, "/*alpha*/")
    }

    func testBlockCommentIsOneUndoGroup() throws {
        let controller = makeController()
        let original = "alpha\nbeta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        document.undoManager.removeAllActions()

        XCTAssertTrue(performBlockComment(in: controller))
        XCTAssertEqual(document.text, "/*alpha\nbeta*/")

        document.undoManager.undo()
        XCTAssertEqual(document.text, original, "one command must be one undo step")
        XCTAssertFalse(document.undoManager.canUndo)
    }

    // MARK: - Menu wiring

    /// P-12: the block-comment command must work when the real Edit menu item
    /// is dispatched, not only when a test calls the parameter-carrying helper.
    /// A regression to the nil-parameter identity path (P-01) makes this fail:
    /// validation may stay enabled but the dispatched action would not mutate
    /// the buffer.
    func testBlockCommentMenuItemDispatchWrapsSwiftSelection() throws {
        let controller = makeController()
        let delegate = HexpadAppDelegate()
        let item = try XCTUnwrap(blockCommentMenuItem(delegate))
        let original = "alpha\nbeta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0,
                                          length: (original as NSString).length))

        XCTAssertTrue(controller.validateMenuItem(item),
                      "Swift declares a block pair, so the item is enabled")
        XCTAssertTrue(dispatchMenuAction(item, to: controller),
                      "the menu action must report that it changed the buffer")
        XCTAssertEqual(document.text, "/*alpha\nbeta*/")

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertTrue(dispatchMenuAction(item, to: controller))
        XCTAssertEqual(document.text, original, "the same item toggles back off")
    }

    func testEditMenuHasCommentSubmenuWithBlockCommand() throws {
        let item = try XCTUnwrap(blockCommentMenuItem(HexpadAppDelegate()))

        XCTAssertEqual(item.representedObject as? String, "toggle-block-comment")
        XCTAssertEqual(item.action,
                       #selector(MainWindowController.performCommentCommand(_:)),
                       "the block command must carry the language-resolved parameter")
        XCTAssertNil(item.target, "resolves through the first responder like the Text menu")
    }

    /// One Comment/Uncomment menu serves every tab, so the action must resolve
    /// the focused language when it runs rather than when the menu was built.
    func testBlockCommentMenuActionResolvesLanguageAtCallTime() throws {
        let controller = makeController()
        let item = try XCTUnwrap(blockCommentMenuItem(HexpadAppDelegate()))

        let document = try useLanguage(.swift, text: "alpha", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        controller.performCommentCommand(item)
        XCTAssertEqual(document.text, "/*alpha*/")

        try useLanguage(.html, text: "alpha", in: controller)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        controller.performCommentCommand(item)
        XCTAssertEqual(document.text, "<!--alpha-->")
    }
}
