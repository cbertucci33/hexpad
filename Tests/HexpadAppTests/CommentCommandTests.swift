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

        XCTAssertTrue(controller.performCommand(identifier: "toggle-block-comment"))
        XCTAssertEqual(document.text, "/*alpha\nbeta*/")

        XCTAssertTrue(controller.performCommand(identifier: "toggle-block-comment"))
        XCTAssertEqual(document.text, original)
    }

    func testHTMLDocumentUsesItsOwnBlockDelimiters() throws {
        let controller = makeController()
        let original = "alpha\nbeta"
        let document = try useLanguage(.html, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-block-comment"))
        XCTAssertEqual(document.text, "<!--alpha\nbeta-->")
    }

    func testBlockCommentPreservesIndentation() throws {
        let controller = makeController()
        let original = "  alpha\n  beta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-block-comment"))
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
        XCTAssertFalse(controller.performCommand(identifier: "toggle-block-comment"))
        XCTAssertEqual(document.text, "alpha", "no guessed `/* */` delimiters")

        try useLanguage(.swift, text: "alpha", in: controller)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(controller.validateMenuItem(item), "Swift declares `/* */`")
    }

    func testBlockCommentIsOneUndoGroup() throws {
        let controller = makeController()
        let original = "alpha\nbeta"
        let document = try useLanguage(.swift, text: original, in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: (original as NSString).length))
        document.undoManager.removeAllActions()

        XCTAssertTrue(controller.performCommand(identifier: "toggle-block-comment"))
        XCTAssertEqual(document.text, "/*alpha\nbeta*/")

        document.undoManager.undo()
        XCTAssertEqual(document.text, original, "one command must be one undo step")
        XCTAssertFalse(document.undoManager.canUndo)
    }

    // MARK: - Menu wiring

    func testEditMenuHasCommentSubmenuWithBlockCommand() throws {
        let item = try XCTUnwrap(blockCommentMenuItem(HexpadAppDelegate()))

        XCTAssertEqual(item.representedObject as? String, "toggle-block-comment")
        XCTAssertEqual(item.action,
                       #selector(MainWindowController.performCommand(withIdentifier:)))
        XCTAssertNil(item.target, "resolves through the first responder like the Text menu")
    }
}
