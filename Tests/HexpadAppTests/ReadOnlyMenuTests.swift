import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P16d-3: Edit > Read-Only (per document) and Read-Only for All Documents.
///
/// Menu structure/targets are inspected on the real menu tree; validation and
/// both actions run through `HexpadAppDelegate` + a real `MainWindowController`.
/// The typing veto is exercised on the controller's bound NSTextView, the same
/// object AppKit routes typed characters through.
final class ReadOnlyMenuTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    private func editMenu(delegate: HexpadAppDelegate) -> NSMenu {
        delegate.makeEditMenu()
    }

    // MARK: - Structure

    func testEditMenuHasBothReadOnlyItemsNearTheEnd() throws {
        let delegate = HexpadAppDelegate()
        let menu = editMenu(delegate: delegate)
        let titles = menu.items.map(\.title)

        XCTAssertEqual(titles.suffix(2),
                       ["Read-Only", "Read-Only for All Documents"])
        let findIndex = try XCTUnwrap(titles.firstIndex(of: "Find..."))
        let readOnlyIndex = try XCTUnwrap(titles.firstIndex(of: "Read-Only"))
        XCTAssertGreaterThan(readOnlyIndex, findIndex, "Read-Only sits near the end of Edit")

        let readOnly = try XCTUnwrap(menu.item(withTitle: "Read-Only"))
        XCTAssertEqual(readOnly.action, #selector(HexpadAppDelegate.toggleReadOnly))
        XCTAssertTrue(readOnly.target === delegate, "delegate-targeted action")
        XCTAssertEqual(readOnly.keyEquivalent, "")

        let all = try XCTUnwrap(menu.item(withTitle: "Read-Only for All Documents"))
        XCTAssertEqual(all.action, #selector(HexpadAppDelegate.toggleReadOnlyForAll))
        XCTAssertTrue(all.target === delegate)
        XCTAssertEqual(all.keyEquivalent, "")
    }

    // MARK: - Validation / checkmarks

    func testCheckmarkAndEnabledStateFollowFocusedDocument() throws {
        let delegate = HexpadAppDelegate()
        let menu = editMenu(delegate: delegate)
        let readOnly = try XCTUnwrap(menu.item(withTitle: "Read-Only"))
        let all = try XCTUnwrap(menu.item(withTitle: "Read-Only for All Documents"))
        let controller = makeController()
        delegate.activeControllerOverride = controller

        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        controller.tabStore.documents = [a, b]
        controller.tabStore.selectedIndex = 0

        XCTAssertTrue(delegate.validateMenuItem(readOnly))
        XCTAssertEqual(readOnly.state, .off)
        XCTAssertEqual(all.state, .off)

        a.setReadOnly(true)
        XCTAssertTrue(delegate.validateMenuItem(readOnly))
        XCTAssertEqual(readOnly.state, .on, "focused read-only document checks the item")
        XCTAssertEqual(all.state, .on)

        controller.tabStore.selectedIndex = 1
        XCTAssertTrue(delegate.validateMenuItem(all))
        XCTAssertEqual(readOnly.state, .off, "a writable focused document unchecks it")

        controller.tabStore.documents = []
        XCTAssertFalse(delegate.validateMenuItem(readOnly), "no focused document")
        XCTAssertFalse(delegate.validateMenuItem(all))
    }

    /// The controller refreshes the delegate-owned items from `updateEditor`,
    /// so switching tabs updates the checkmark before the menu reopens.
    func testTabSwitchRefreshesCheckmarksThroughUpdateEditor() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? HexpadAppDelegate)
        let menu = editMenu(delegate: delegate)
        let readOnly = try XCTUnwrap(menu.item(withTitle: "Read-Only"))
        let all = try XCTUnwrap(menu.item(withTitle: "Read-Only for All Documents"))
        let controller = makeController()
        let previousOverride = delegate.activeControllerOverride
        delegate.activeControllerOverride = controller
        defer { delegate.activeControllerOverride = previousOverride }

        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        controller.tabStore.documents = [a, b]
        a.setReadOnly(true)

        controller.tabStore.selectedIndex = 0
        controller.updateEditor()
        XCTAssertEqual(readOnly.state, .on)
        XCTAssertEqual(all.state, .on)

        controller.tabStore.selectedIndex = 1
        controller.updateEditor()
        XCTAssertEqual(readOnly.state, .off)
        XCTAssertEqual(all.state, .off)

        b.setReadOnly(true)
        controller.toggleReadOnly()
        XCTAssertFalse(b.isReadOnly)
        XCTAssertEqual(readOnly.state, .off, "the toggle also refreshes the checkmark")
    }

    // MARK: - Actions

    func testReadOnlyTogglesOnlyTheFocusedDocument() {
        let controller = makeController()
        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        controller.tabStore.documents = [a, b]
        controller.tabStore.selectedIndex = 0
        let delegate = HexpadAppDelegate()
        delegate.activeControllerOverride = controller

        delegate.toggleReadOnly()
        XCTAssertTrue(a.isReadOnly)
        XCTAssertFalse(b.isReadOnly, "the other tab keeps its own state")

        delegate.toggleReadOnly()
        XCTAssertFalse(a.isReadOnly)
        XCTAssertFalse(b.isReadOnly)
    }

    func testReadOnlyForAllUsesTheFocusedDocumentsNewState() {
        let controller = makeController()
        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        let c = DocumentModel(text: "c")
        controller.tabStore.documents = [a, b, c]
        controller.tabStore.selectedIndex = 1
        let delegate = HexpadAppDelegate()
        delegate.activeControllerOverride = controller

        // All writable -> focused becomes read-only -> every tab locks.
        delegate.toggleReadOnlyForAll()
        XCTAssertTrue(a.isReadOnly && b.isReadOnly && c.isReadOnly)

        // Focused becomes writable again -> every tab unlocks.
        delegate.toggleReadOnlyForAll()
        XCTAssertFalse(a.isReadOnly || b.isReadOnly || c.isReadOnly)

        // Mixed start: only b is writable, so the next "all" locks everything.
        a.setReadOnly(true)
        c.setReadOnly(true)
        delegate.toggleReadOnlyForAll()
        XCTAssertTrue(a.isReadOnly && b.isReadOnly && c.isReadOnly)
    }

    func testReadOnlyForAllSpansBothSplitPanes() {
        let controller = makeController()
        controller.openSplitView()
        let primary = controller.allPanes[0]
        let secondary = controller.allPanes[1]
        let a = DocumentModel(text: "a")
        let b = DocumentModel(text: "b")
        let c = DocumentModel(text: "c")
        primary.tabStore.documents = [a]
        secondary.tabStore.documents = [b, c]
        controller.focusGroup(.secondary)
        let delegate = HexpadAppDelegate()
        delegate.activeControllerOverride = controller

        delegate.toggleReadOnlyForAll()
        XCTAssertTrue(a.isReadOnly, "the unfocused pane is included")
        XCTAssertTrue(b.isReadOnly && c.isReadOnly)
    }

    // MARK: - Editor enforcement

    func testReadOnlyBufferRejectsTypingButKeepsNavigationSelectionAndCopy() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "abcdef")
        controller.updateEditor()
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.setReadOnly(true)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertText("X", replacementRange: textView.selectedRange)
        XCTAssertEqual(doc.text, "abcdef", "typing must not mutate a read-only buffer")
        XCTAssertEqual(textView.string, "abcdef")

        // Caret movement and selection never route through the veto.
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(textView.selectedRange.location, 4)
        textView.setSelectedRange(NSRange(location: 1, length: 3))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 3))

        // Copy is still available: selection survives and the pasteboard gets
        // the chosen characters.
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "bcd")

        doc.setReadOnly(false)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("Y", replacementRange: textView.selectedRange)
        XCTAssertEqual(doc.text, "Yabcdef", "a writable buffer still accepts typing")
    }

    /// Paste and drag-and-drop enter through `shouldChangeTextIn` too; a single
    /// veto must stop them without special-casing each insertion source.
    func testReadOnlyBufferRejectsPaste() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "base")
        controller.updateEditor()
        let textView = try XCTUnwrap(controller.editorTextView)

        // clearContents first: setString on a pasteboard holding foreign/rich
        // content can fail (verified 2026-11-21 - setString without a prior
        // clear returns false from a fresh process). The test owns the
        // pasteboard state instead of inheriting whatever ran before it.
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("pasted", forType: .string))
        doc.setReadOnly(true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.paste(nil)
        XCTAssertEqual(doc.text, "base", "pasting into a read-only buffer is a no-op")

        doc.setReadOnly(false)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.paste(nil)
        XCTAssertEqual(doc.text, "pastedbase", "the same paste lands once writable")
    }

    /// Locking a buffer is not a content edit: its dirty dot is unaffected,
    /// and while it is locked every programmatic mutation is a no-op.
    func testReadOnlyDoesNotChangeTheDirtyFlag() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.setModified(false)
        XCTAssertFalse(doc.isModified)
        let text = doc.text

        delegateToggle(controller)
        XCTAssertTrue(doc.isReadOnly)
        XCTAssertFalse(doc.isModified)

        doc.replaceCharacters(in: NSRange(location: 0, length: doc.textStorage.length),
                              with: "changed")
        XCTAssertEqual(doc.text, text, "a read-only buffer rejects direct mutations")
        XCTAssertFalse(doc.isModified, "a rejected mutation leaves the dirty flag alone")

        delegateToggle(controller)
        XCTAssertFalse(doc.isReadOnly)
        doc.replaceCharacters(in: NSRange(location: 0, length: doc.textStorage.length),
                              with: "changed")
        XCTAssertTrue(doc.isModified, "the buffer accepts mutations once unlocked")
    }

    // MARK: - Programmatic enforcement (registry commands, macros, find)

    /// The command registry funnels through the shared buffer: on a read-only
    /// document a case transform or a sort must not change the text.
    func testPerformCommandOnReadOnlyDocumentIsANoOp() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "beta\nalpha")
        controller.updateEditor()
        doc.setReadOnly(true)

        controller.performCommand(identifier: "sort-lines-ascending")
        XCTAssertEqual(doc.text, "beta\nalpha",
                       "a read-only buffer rejects registry commands")

        controller.performCommand(identifier: "case-uppercase")
        XCTAssertEqual(doc.text, "beta\nalpha",
                       "a read-only buffer rejects case commands")
    }

    /// Macro replay applies its steps through the same command path; a macro
    /// that would change a read-only buffer must not change it.
    func testMacroReplayOnReadOnlyDocumentIsANoOp() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "beta\nalpha")
        controller.updateEditor()

        let macro = MacroModel(name: "Sort replay",
                               steps: [MacroStep(identifier: "sort-lines-ascending")])

        // Baseline: the same replay sorts when the buffer is writable.
        XCTAssertTrue(controller.playMacro(macro))
        XCTAssertEqual(doc.text, "alpha\nbeta")

        doc.replaceAllText(with: "beta\nalpha")
        doc.setReadOnly(true)
        controller.playMacro(macro)
        XCTAssertEqual(doc.text, "beta\nalpha", "a read-only buffer rejects macro replay")
    }

    /// The Find & Replace path applies through `doc.replaceCharacters`; a
    /// read-only buffer must reject it too.
    func testFindReplaceOnReadOnlyDocumentIsANoOp() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "one two one two")
        controller.updateEditor()
        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible {
            controller.toggleFindBar()
        }
        doc.setReadOnly(true)

        bar.searchField.stringValue = "one"
        let replaceField = try XCTUnwrap(
            bar.subviews.compactMap { $0 as? NSSearchField }
                .first { $0.placeholderString == "Replace..." })
        replaceField.stringValue = "X"
        bar.performFind()

        let replaceButton = try XCTUnwrap(
            bar.subviews.compactMap { $0 as? NSButton }
                .first { $0.title == "Replace" })
        replaceButton.performClick(nil)

        XCTAssertEqual(doc.text, "one two one two", "Replace must not mutate a read-only buffer")
    }

    private func delegateToggle(_ controller: MainWindowController) {
        let delegate = HexpadAppDelegate()
        delegate.activeControllerOverride = controller
        delegate.toggleReadOnly()
    }
}
