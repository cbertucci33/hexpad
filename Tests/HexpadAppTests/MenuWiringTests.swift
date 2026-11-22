import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Menu-wiring coverage for the command registry. These exercise the real app
/// menu tree and the controller that backs the nil-targeted first-responder
/// actions, mirroring the LayoutTests approach of instantiating app objects
/// rather than duplicating their logic in the test.
final class MenuWiringTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Menu tests must not read the developer's real keybindings.json.
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-menu-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        if let keybindingDirectory {
            try? FileManager.default.removeItem(at: keybindingDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func commandItem(_ identifier: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { ($0.representedObject as? String) == identifier }
    }

    private func commandValidationItem(_ identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: identifier,
                              action: #selector(MainWindowController.performCommand(withIdentifier:)),
                              keyEquivalent: "")
        item.representedObject = identifier
        return item
    }

    // MARK: - Text menu

    func testTextMenuMirrorsRegistryCommandsInOrder() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let textItem = try XCTUnwrap(menu.item(withTitle: "Text"))
        let textMenu = try XCTUnwrap(textItem.submenu)

        let commandItems = textMenu.items.filter {
            $0.action == #selector(MainWindowController.performCommand(withIdentifier:))
        }
        XCTAssertEqual(commandItems.map(\.title), CommandRegistry.default.commands.map(\.title))

        for (item, command) in zip(commandItems, CommandRegistry.default.commands) {
            XCTAssertEqual(item.representedObject as? String, command.identifier)
            XCTAssertNil(item.target, "commands must resolve through the first responder chain")
            XCTAssertEqual(item.action, #selector(MainWindowController.performCommand(withIdentifier:)))
        }
    }

    func testTextMenuUsesDefaultKeyEquivalents() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let textMenu = try XCTUnwrap(menu.item(withTitle: "Text")?.submenu)

        let expected: [String: (key: String, mask: NSEvent.ModifierFlags)] = [
            "duplicate-line": ("d", [.command]),
            "delete-line": ("d", [.command, .shift]),
            "move-line-up": (EditorCommandBinding.upArrow, [.command, .option]),
            "move-line-down": (EditorCommandBinding.downArrow, [.command, .option]),
            "toggle-line-comment": ("/", [.command]),
            "uppercase": ("u", [.command, .shift]),
            "lowercase": ("u", [.command])
        ]

        for (identifier, shortcut) in expected {
            let item = try XCTUnwrap(commandItem(identifier, in: textMenu), identifier)
            XCTAssertEqual(item.keyEquivalent, shortcut.key, identifier)
            XCTAssertEqual(item.keyEquivalentModifierMask, shortcut.mask, identifier)
        }
    }

    // MARK: - Command execution

    /// Copy to Clipboard variants: Current entries read the focused tab, All
    /// entries span every tab, and untitled buffers contribute nothing.
    func testCopyPathVariantsCoverFileBackedAndUntitledDocuments() {
        let alpha = DocumentModel(text: "a",
                                  filePath: URL(fileURLWithPath: "/tmp/hexpad-alpha.txt"))
        let untitled = DocumentModel(text: "b")
        let beta = DocumentModel(text: "c",
                                 filePath: URL(fileURLWithPath: "/Users/cb/notes/beta.md"))
        let documents = [alpha, untitled, beta]

        XCTAssertEqual(CopyPathCollector.text(for: .currentFullPath,
                                              selected: alpha,
                                              documents: documents),
                       "/tmp/hexpad-alpha.txt")
        XCTAssertEqual(CopyPathCollector.text(for: .currentFilename,
                                              selected: beta,
                                              documents: documents),
                       "beta.md")
        XCTAssertEqual(CopyPathCollector.text(for: .currentDirectory,
                                              selected: alpha,
                                              documents: documents),
                       "/tmp")
        XCTAssertNil(CopyPathCollector.text(for: .currentFullPath,
                                            selected: untitled,
                                            documents: documents))
        XCTAssertNil(CopyPathCollector.text(for: .currentFilename,
                                            selected: untitled,
                                            documents: documents))
        XCTAssertNil(CopyPathCollector.text(for: .currentDirectory,
                                            selected: untitled,
                                            documents: documents))

        XCTAssertEqual(CopyPathCollector.text(for: .allFilenames,
                                              selected: untitled,
                                              documents: documents),
                       "hexpad-alpha.txt\nbeta.md")
        XCTAssertEqual(CopyPathCollector.text(for: .allPaths,
                                              selected: untitled,
                                              documents: documents),
                       "/tmp/hexpad-alpha.txt\n/Users/cb/notes/beta.md")
        XCTAssertNil(CopyPathCollector.text(for: .allPaths,
                                            selected: untitled,
                                            documents: [untitled]))
    }

    func testPerformCommandAppliesCommandAsSingleUndoStep() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "one\ntwo")
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "duplicate-line"))
        XCTAssertEqual(doc.text, "one\ntwo\ntwo")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 0))

        // One command = one undoable replacement.
        doc.undoManager.undo()
        XCTAssertEqual(doc.text, "one\ntwo")
    }

    func testPerformCommandPostsDocumentModifiedNotifications() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "alpha\nbeta")
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        var modelChanges = 0
        var modifiedChanges = 0
        let center = NotificationCenter.default
        let modelToken = center.addObserver(forName: DocumentModel.textDidChangeNotification,
                                            object: doc,
                                            queue: nil) { _ in modelChanges += 1 }
        let modifiedToken = center.addObserver(forName: NSNotification.Name("DocumentModifiedDidChange"),
                                               object: nil,
                                               queue: nil) { _ in modifiedChanges += 1 }
        defer {
            center.removeObserver(modelToken)
            center.removeObserver(modifiedToken)
        }

        XCTAssertFalse(controller.performCommand(identifier: "uppercase"),
                       "a caret-only uppercase is a no-op")

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(controller.performCommand(identifier: "uppercase"))
        XCTAssertEqual(doc.text, "ALPHA\nbeta")
        XCTAssertGreaterThanOrEqual(modelChanges, 1)
        XCTAssertGreaterThanOrEqual(modifiedChanges, 1)
    }

    // MARK: - Menu validation

    func testValidationDisablesCommandsWithoutDocument() throws {
        let (controller, _) = makeController()
        controller.tabStore.documents.removeAll()

        XCTAssertFalse(controller.canPerformCommand(identifier: "duplicate-line"))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("duplicate-line")))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("unknown-command")))
    }

    func testValidationReflectsCommandApplicability() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "one\ntwo")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // A caret on the first line can duplicate/delete, but cannot
        // move up or change case. The default document has no language
        // metadata, and since the no-fallback resolver (P17f) there is no
        // guessed token: *** must be disabled.
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("duplicate-line")))
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("delete-line")))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("toggle-line-comment")))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("move-line-up")))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("uppercase")))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("lowercase")))

        // A non-empty selection enables case changes where the transform
        // actually changes something: "one" can be uppercased but not
        // lowercased.
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("uppercase")))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("lowercase")))

        // The mirror image: already-uppercase text can only be lowercased.
        doc.replaceAllText(with: "ONE\ntwo")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertFalse(controller.validateMenuItem(commandValidationItem("uppercase")))
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("lowercase")))
    }

    // MARK: - Tab navigation

    func testTabNavigationWrapsAndSelectsByNumber() throws {
        let (controller, _) = makeController()
        XCTAssertEqual(controller.tabStore.count, 1)
        XCTAssertEqual(controller.tabStore.selectedIndex, 0)

        controller.addNewTab()
        XCTAssertEqual(controller.tabStore.count, 2)
        XCTAssertEqual(controller.tabStore.selectedIndex, 1)

        controller.selectNextTab()
        XCTAssertEqual(controller.tabStore.selectedIndex, 0)

        controller.selectPreviousTab()
        XCTAssertEqual(controller.tabStore.selectedIndex, 1)

        controller.selectTab(at: 0)
        XCTAssertEqual(controller.tabStore.selectedIndex, 0)

        let secondTab = NSMenuItem()
        secondTab.tag = 2
        controller.selectTabByNumber(secondTab)
        XCTAssertEqual(controller.tabStore.selectedIndex, 1)

        let outOfRange = NSMenuItem()
        outOfRange.tag = 9
        controller.selectTabByNumber(outOfRange)
        XCTAssertEqual(controller.tabStore.selectedIndex, 1)
    }

    func testWindowMenuTabShortcuts() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)

        let next = try XCTUnwrap(windowMenu.item(withTitle: "Next Tab"))
        XCTAssertEqual(next.keyEquivalent, "]")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(next.target)
        XCTAssertEqual(next.action, #selector(MainWindowController.selectNextTab(_:)))

        let previous = try XCTUnwrap(windowMenu.item(withTitle: "Previous Tab"))
        XCTAssertEqual(previous.keyEquivalent, "[")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(previous.target)
        XCTAssertEqual(previous.action, #selector(MainWindowController.selectPreviousTab(_:)))

        for number in 1...9 {
            let item = try XCTUnwrap(windowMenu.item(withTitle: "Tab \(number)"))
            XCTAssertEqual(item.keyEquivalent, "\(number)")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
            XCTAssertEqual(item.tag, number)
            XCTAssertNil(item.target)
            XCTAssertEqual(item.action, #selector(MainWindowController.selectTabByNumber(_:)))
        }
    }

    func testTabMenuValidationTracksTabCount() throws {
        let (controller, _) = makeController()

        let next = NSMenuItem(title: "Next Tab",
                              action: #selector(MainWindowController.selectNextTab(_:)),
                              keyEquivalent: "")
        let previous = NSMenuItem(title: "Previous Tab",
                                  action: #selector(MainWindowController.selectPreviousTab(_:)),
                                  keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(next), "one tab has nowhere to go")
        XCTAssertFalse(controller.validateMenuItem(previous))

        controller.addNewTab()
        XCTAssertTrue(controller.validateMenuItem(next))
        XCTAssertTrue(controller.validateMenuItem(previous))

        let tab2 = NSMenuItem(title: "Tab 2",
                              action: #selector(MainWindowController.selectTabByNumber(_:)),
                              keyEquivalent: "")
        tab2.tag = 2
        XCTAssertTrue(controller.validateMenuItem(tab2))

        tab2.tag = 3
        XCTAssertFalse(controller.validateMenuItem(tab2))
    }

    // MARK: - File > Close Multiple Documents

    /// Bulk-close menu wiring plus the clean-document sweep. Dirty-document
    /// prompting runs through NSAlert sheets and is not exercised here; the
    /// sweep itself is shared with Close All Tabs.
    func testCloseMultipleDocumentsMenuWiringAndCleanSweep() throws {
        let delegate = HexpadAppDelegate()
        let menu = delegate.buildMainMenu()
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let bulkItem = try XCTUnwrap(fileMenu.item(withTitle: "Close Multiple Documents"))
        let bulkMenu = try XCTUnwrap(bulkItem.submenu)

        let expected: [(title: String, action: Selector)] = [
            ("Close All but Active Document", #selector(HexpadAppDelegate.closeAllButActiveDocument)),
            ("Close All but Pinned Documents", #selector(HexpadAppDelegate.closeAllButPinnedDocuments)),
            ("Close All to the Left", #selector(HexpadAppDelegate.closeAllDocumentsToLeft)),
            ("Close All to the Right", #selector(HexpadAppDelegate.closeAllDocumentsToRight)),
            ("Close All Unchanged", #selector(HexpadAppDelegate.closeAllUnchangedDocuments))
        ]
        XCTAssertEqual(bulkMenu.items.map(\.title), expected.map(\.title))
        for (item, entry) in zip(bulkMenu.items, expected) {
            XCTAssertEqual(item.action, entry.action, entry.title)
            XCTAssertTrue(item.target === delegate, entry.title)
        }

        let (controller, _) = makeController()
        XCTAssertFalse(controller.canCloseMultipleDocuments(.allButActive),
                       "one tab has nothing else to close")

        controller.tabStore.addDocument(DocumentModel(text: "b"))
        controller.tabStore.addDocument(DocumentModel(text: "c"))
        controller.selectTab(at: 1)
        XCTAssertTrue(controller.canCloseMultipleDocuments(.allButActive))
        XCTAssertTrue(controller.canCloseMultipleDocuments(.toLeftOfActive))
        XCTAssertTrue(controller.canCloseMultipleDocuments(.toRightOfActive))

        controller.closeMultipleDocuments(.allButActive)
        XCTAssertEqual(controller.tabStore.documents.map(\.text), ["b"])
        XCTAssertEqual(controller.tabStore.selectedDocument?.text, "b")

        // Unchanged closes clean tabs and leaves dirty ones open.
        let dirty = DocumentModel(text: "dirty")
        dirty.setModified(true)
        controller.tabStore.addDocument(dirty)
        controller.tabStore.addDocument(DocumentModel(text: "clean"))
        controller.selectTab(at: 1)
        XCTAssertTrue(controller.canCloseMultipleDocuments(.unchanged))
        controller.closeMultipleDocuments(.unchanged)
        XCTAssertEqual(controller.tabStore.documents.map(\.text), ["dirty"])
    }

    // MARK: - Encoding menu (Encode in / Convert to)

    private func encodingItem(_ name: String,
                              action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.representedObject = name
        return item
    }

    func testEncodingMenuHasEncodeInAndConvertToSections() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let encodingMenu = try XCTUnwrap(menu.item(withTitle: "Encoding")?.submenu)

        let sections = encodingMenu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(Array(sections.prefix(2).map(\.title)), ["Encode in", "Convert to"])

        let encodeIn = try XCTUnwrap(sections.first { $0.title == "Encode in" }?.submenu)
        let convertTo = try XCTUnwrap(sections.first { $0.title == "Convert to" }?.submenu)
        let expectedNames = MainWindowController.encodingOptions.map(\.name)

        XCTAssertEqual(encodeIn.items.map { $0.representedObject as? String }, expectedNames)
        XCTAssertEqual(convertTo.items.map { $0.representedObject as? String }, expectedNames)

        for item in encodeIn.items {
            XCTAssertNil(item.target, "validation reaches the controller through the responder chain")
            XCTAssertEqual(item.action, #selector(MainWindowController.encodeIn(_:)))
        }
        for item in convertTo.items {
            XCTAssertNil(item.target)
            XCTAssertEqual(item.action, #selector(MainWindowController.convertToEncoding(_:)))
        }
    }

    func testEncodingCheckmarksTrackDecodeAndSaveEncodingsSeparately() throws {
        let (controller, _) = makeController()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-menu-encoding-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("hello".utf8).write(to: tmp)

        let doc = DocumentModel(text: "hello", filePath: tmp, encoding: "UTF-8")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
        controller.updateEditor()

        let encodeUTF8 = encodingItem("UTF-8", action: #selector(MainWindowController.encodeIn(_:)))
        let encodeUTF16 = encodingItem("UTF-16LE", action: #selector(MainWindowController.encodeIn(_:)))
        let convertUTF8 = encodingItem("UTF-8", action: #selector(MainWindowController.convertToEncoding(_:)))
        let convertUTF16 = encodingItem("UTF-16LE", action: #selector(MainWindowController.convertToEncoding(_:)))

        // Both sections initially mark the document's only encoding.
        XCTAssertTrue(controller.validateMenuItem(encodeUTF8))
        XCTAssertEqual(encodeUTF8.state, .on)
        XCTAssertTrue(controller.validateMenuItem(convertUTF8))
        XCTAssertEqual(convertUTF8.state, .on)

        // "Convert to" retargets the save; the decode checkmark must not move.
        controller.convertToEncoding("UTF-16LE")
        XCTAssertEqual(doc.encoding, "UTF-8")
        XCTAssertEqual(doc.saveEncoding, "UTF-16LE")
        XCTAssertTrue(doc.isModified)

        XCTAssertTrue(controller.validateMenuItem(encodeUTF8))
        XCTAssertEqual(encodeUTF8.state, .on, "Encode in still marks the decode encoding")
        XCTAssertTrue(controller.validateMenuItem(convertUTF8), "a valid target stays selectable")
        XCTAssertEqual(convertUTF8.state, .off)
        XCTAssertTrue(controller.validateMenuItem(convertUTF16))
        XCTAssertEqual(convertUTF16.state, .on, "Convert to marks the next save's encoding")
        XCTAssertTrue(controller.validateMenuItem(encodeUTF16), "a file-backed doc can reinterpret as any encoding")
        XCTAssertEqual(encodeUTF16.state, .off)
    }

    func testEncodingValidationNeedsAnOpenDocumentWithRawBytes() throws {
        let (controller, _) = makeController()

        let encodeUTF8 = encodingItem("UTF-8", action: #selector(MainWindowController.encodeIn(_:)))
        let convertUTF8 = encodingItem("UTF-8", action: #selector(MainWindowController.convertToEncoding(_:)))

        // The default tab is untitled: no raw bytes to reinterpret.
        XCTAssertFalse(controller.validateMenuItem(encodeUTF8))
        XCTAssertTrue(controller.validateMenuItem(convertUTF8))

        // Unsupported targets are disabled for the current content.
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "😀")
        let convertASCII = encodingItem("ASCII", action: #selector(MainWindowController.convertToEncoding(_:)))
        XCTAssertFalse(controller.validateMenuItem(convertASCII))

        // No document at all: every encoding item is disabled.
        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(encodeUTF8))
        XCTAssertFalse(controller.validateMenuItem(convertUTF8))
    }

    func testTabDragPreviewCommitsOnceAcrossSlots() {
        let store = TabStore()
        for text in ["a", "b", "c", "d"] {
            store.addDocument(DocumentModel(text: text))
        }
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.reloadTabs()

        var changes = 0
        bar.onChange = { changes += 1 }

        bar.beginDragPreview(from: 0)
        bar.previewDrag(to: 1)
        bar.previewDrag(to: 2)
        bar.previewDrag(to: 3)
        XCTAssertEqual(changes, 0, "previewing must not mutate or notify")

        bar.commitDragPreview()
        XCTAssertEqual(changes, 1, "one commit on mouseUp, not one per slot")
        XCTAssertEqual(store.documents.map(\.text), ["b", "c", "d", "a"])
    }

    // MARK: - R4: Find Next after the bar closed

    func testFindNextAfterClosingFindBarClampsToCurrentBuffer() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha alpha alpha"

        controller.toggleFindBar()
        let bar = try XCTUnwrap(controller.findBar)
        XCTAssertTrue(bar.isVisible)
        bar.searchField.stringValue = "alpha"
        bar.performFind()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3")

        // Close the bar while it holds three matches, then delete them all.
        controller.toggleFindBar()
        XCTAssertFalse(bar.isVisible)
        doc.text = "zzz"
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // Used to hand NSTextView a 5-character range inside a 3-character
        // buffer, raising NSRangeException.
        controller.findNext()

        let length = (doc.text as NSString).length
        let selection = try XCTUnwrap(controller.editorTextView?.selectedRange)
        XCTAssertLessThanOrEqual(NSMaxRange(selection), length,
                                 "Find Next must never select past the buffer")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "No matches",
                       "the stale match list must be discarded, not reused")
    }

    // MARK: - R5: programmatic tab switches refresh the find bar

    func testSelectTabRefreshesFindBarCounts() throws {
        let (controller, _) = makeController()
        let first = try XCTUnwrap(controller.tabStore.selectedDocument)
        first.text = "needle needle"

        controller.addNewTab()
        let second = try XCTUnwrap(controller.tabStore.selectedDocument)
        second.text = "haystack"

        controller.selectTab(at: 0)
        controller.toggleFindBar()
        let bar = try XCTUnwrap(controller.findBar)
        bar.searchField.stringValue = "needle"
        bar.performFind()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")

        // Cmd+1-9 / Cmd+Shift+] / doc-switcher path: only the controller's
        // selectTab runs, and it must post the tab-selection notice.
        controller.selectTab(at: 1)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "No matches",
                       "the find bar must re-search the newly selected document")

        controller.selectTab(at: 0)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")
    }

    // MARK: - View > View Current File In

    func testViewMenuHasViewCurrentFileInDefaultBrowser() throws {
        let delegate = HexpadAppDelegate()
        let menu = delegate.buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let viewCurrentItem = try XCTUnwrap(viewMenu.item(withTitle: "View Current File In"))
        let viewCurrentMenu = try XCTUnwrap(viewCurrentItem.submenu)

        let defaultBrowser = try XCTUnwrap(viewCurrentMenu.items.first { $0.title == "Default Browser" })
        XCTAssertEqual(defaultBrowser.action, #selector(HexpadAppDelegate.viewCurrentFileInBrowser(_:)))
        XCTAssertNil(defaultBrowser.target, "validation reaches the delegate through the responder chain")
        XCTAssertEqual(defaultBrowser.keyEquivalent, "")
    }

    // MARK: - Help menu

    /// Help carries the two N++-parity links after About, and each item holds a
    /// real URL for the shared browser action. No NSWorkspace call here: the
    /// test only inspects wiring, never opens a browser.
    func testHelpMenuHasManualAndProjectLinks() throws {
        let delegate = HexpadAppDelegate()
        let helpMenu = delegate.makeHelpMenu()

        XCTAssertEqual(helpMenu.items.first?.title, "About Hexpad")

        let manual = try XCTUnwrap(helpMenu.item(withTitle: "Hexpad Online Manual"))
        let project = try XCTUnwrap(helpMenu.item(withTitle: "Hexpad Project Page"))

        let manualURL = try XCTUnwrap(manual.representedObject as? URL)
        let projectURL = try XCTUnwrap(project.representedObject as? URL)
        XCTAssertEqual(manualURL.absoluteString, HexpadAppDelegate.onlineManualURL)
        XCTAssertEqual(projectURL.absoluteString, HexpadAppDelegate.projectPageURL)
        XCTAssertEqual(manualURL.scheme, "https")
        XCTAssertEqual(projectURL.scheme, "https")

        for item in [manual, project] {
            XCTAssertEqual(item.action, #selector(HexpadAppDelegate.openHelpLink(_:)))
            XCTAssertTrue(item.target is HexpadAppDelegate)
            XCTAssertTrue(item.isEnabled, "a parsed URL keeps the link enabled")
        }
    }

    // MARK: - File > Open Recent commands

    /// Points SessionStore at a throwaway directory so recents tests never read
    /// or write the real session file, then hands back a fresh manager.
    private func withIsolatedRecents(_ body: (RecentFilesManager) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-recents-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = directory
        defer {
            SessionStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try body(RecentFilesManager())
    }

    /// The submenu carries N++'s three commands after the file list; the
    /// initial build must include them, since only menuNeedsUpdate adds files.
    func testOpenRecentSubmenuHasTheThreeRecentFileCommands() throws {
        let delegate = HexpadAppDelegate()
        let openRecent = try XCTUnwrap(delegate.makeFileMenu().item(withTitle: "Open Recent")?.submenu)

        XCTAssertEqual(Array(openRecent.items.map(\.title).suffix(3)),
                       ["Restore Recent Closed File", "Open All Recent Files", "Empty Recent Files List"])

        let restore = try XCTUnwrap(openRecent.item(withTitle: "Restore Recent Closed File"))
        XCTAssertEqual(restore.action, #selector(HexpadAppDelegate.restoreRecentClosedFile))
        XCTAssertTrue(restore.target is HexpadAppDelegate)

        let openAll = try XCTUnwrap(openRecent.item(withTitle: "Open All Recent Files"))
        XCTAssertEqual(openAll.action, #selector(HexpadAppDelegate.openAllRecentFiles))
        XCTAssertTrue(openAll.target is HexpadAppDelegate)

        let empty = try XCTUnwrap(openRecent.item(withTitle: "Empty Recent Files List"))
        XCTAssertEqual(empty.action, #selector(HexpadAppDelegate.emptyRecentFilesList))
        XCTAssertTrue(empty.target is HexpadAppDelegate)
    }

    /// Rebuilding for display keeps the three commands, and with no recents
    /// they validate as disabled.
    func testOpenRecentCommandsSurviveMenuRebuildAndValidateOnEmptyList() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-recents-menu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SessionStore.overrideDirectory = directory
        defer {
            SessionStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let delegate = HexpadAppDelegate()
        let openRecent = try XCTUnwrap(delegate.makeFileMenu().item(withTitle: "Open Recent")?.submenu)
        delegate.menuNeedsUpdate(openRecent)

        let restore = try XCTUnwrap(openRecent.item(withTitle: "Restore Recent Closed File"))
        let openAll = try XCTUnwrap(openRecent.item(withTitle: "Open All Recent Files"))
        let empty = try XCTUnwrap(openRecent.item(withTitle: "Empty Recent Files List"))
        XCTAssertEqual(openRecent.items.map(\.title),
                       ["No Recent Files", "", "Restore Recent Closed File",
                        "Open All Recent Files", "Empty Recent Files List"])
        XCTAssertFalse(delegate.validateMenuItem(restore))
        XCTAssertFalse(delegate.validateMenuItem(openAll))
        XCTAssertFalse(delegate.validateMenuItem(empty))
    }

    func testRecentFilesManagerRemoveAllClearsList() throws {
        try withIsolatedRecents { manager in
            manager.addRecent("/tmp/hexpad-recents-a.txt")
            manager.addRecent("/tmp/hexpad-recents-b.txt")
            XCTAssertFalse(manager.recents.isEmpty)

            manager.removeAll()

            XCTAssertTrue(manager.recents.isEmpty)
            XCTAssertNil(manager.mostRecentClosedFile())
        }
    }

    /// "Most recent closed" is the newest entry not currently open: the manager
    /// has no separate closed history, so open tabs are the exclusion signal.
    func testMostRecentClosedFileSkipsCurrentlyOpenEntries() throws {
        try withIsolatedRecents { manager in
            manager.addRecent("/tmp/hexpad-recents-b.txt")
            manager.addRecent("/tmp/hexpad-recents-a.txt") // newest

            XCTAssertEqual(manager.mostRecentClosedFile()?.path, "/tmp/hexpad-recents-a.txt")
            XCTAssertEqual(manager.mostRecentClosedFile(openPaths: ["/tmp/hexpad-recents-a.txt"])?.path,
                           "/tmp/hexpad-recents-b.txt")
            XCTAssertNil(manager.mostRecentClosedFile(openPaths: Set(manager.recents)))
        }
    }

    // MARK: - File > Open Containing Folder / Open in Default Viewer

    /// Both hand-offs are nil-targeted delegate actions placed in N++'s order:
    /// the submenu right after Open..., the viewer item at the end of the open
    /// group, ahead of Save.
    func testFileMenuHasOpenContainingFolderAndDefaultViewerItems() throws {
        let delegate = HexpadAppDelegate()
        let fileMenu = delegate.makeFileMenu()

        XCTAssertEqual(Array(fileMenu.items.prefix(10).map(\.title)),
                       ["New Window", "New Tab", "Open...", "Open Containing Folder",
                        "Open Recent", "Open Folder as Workspace…", "Open in Default Viewer",
                        "Save", "Save As...", "Save All"])

        let containingItem = try XCTUnwrap(fileMenu.item(withTitle: "Open Containing Folder"))
        let containingMenu = try XCTUnwrap(containingItem.submenu)

        XCTAssertEqual(containingMenu.items.map(\.title), ["Finder", "Terminal"])

        let finder = try XCTUnwrap(containingMenu.item(withTitle: "Finder"))
        XCTAssertEqual(finder.action, #selector(HexpadAppDelegate.openContainingFolderInFinder(_:)))
        XCTAssertNil(finder.target, "validation reaches the delegate through the responder chain")
        XCTAssertEqual(finder.keyEquivalent, "")

        let terminal = try XCTUnwrap(containingMenu.item(withTitle: "Terminal"))
        XCTAssertEqual(terminal.action, #selector(HexpadAppDelegate.openContainingFolderInTerminal(_:)))
        XCTAssertNil(terminal.target)
        XCTAssertEqual(terminal.keyEquivalent, "")

        let viewer = try XCTUnwrap(fileMenu.item(withTitle: "Open in Default Viewer"))
        XCTAssertEqual(viewer.action, #selector(HexpadAppDelegate.openInDefaultViewer(_:)))
        XCTAssertNil(viewer.target)
        XCTAssertNil(viewer.submenu)
        XCTAssertEqual(viewer.keyEquivalent, "")
    }

    /// The shared gate behind all three commands: no file, no menu item. With
    /// no window at all (no focused document) both containing-folder leaves
    /// validate as disabled, exactly like the untitled case.
    func testExternallyOpeningCommandsValidateFalseWithoutAFile() {
        let delegate = HexpadAppDelegate()
        XCTAssertNil(delegate.selectedFileURL())

        let finder = NSMenuItem(title: "Finder",
                                action: #selector(HexpadAppDelegate.openContainingFolderInFinder(_:)),
                                keyEquivalent: "")
        let terminal = NSMenuItem(title: "Terminal",
                                  action: #selector(HexpadAppDelegate.openContainingFolderInTerminal(_:)),
                                  keyEquivalent: "")
        XCTAssertFalse(delegate.validateMenuItem(finder))
        XCTAssertFalse(delegate.validateMenuItem(terminal))
    }

    /// Open in Default Viewer follows Notepad++ and disables itself when Launch
    /// Services resolves the file back to Hexpad. The policy takes both apps as
    /// arguments, so no NSWorkspace call happens here.
    func testOpenInDefaultViewerPredicateSkipsUntitledAndSelfHandler() {
        let selfApp = URL(fileURLWithPath: "/Applications/Hexpad.app")
        let otherApp = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let file = URL(fileURLWithPath: "/tmp/hexpad-notes.txt")

        XCTAssertFalse(HexpadAppDelegate.canOpenInDefaultViewer(fileURL: nil,
                                                               defaultApplication: otherApp,
                                                               selfApplication: selfApp),
                       "untitled buffers have no file to hand to Launch Services")
        XCTAssertFalse(HexpadAppDelegate.canOpenInDefaultViewer(fileURL: nil,
                                                               defaultApplication: selfApp,
                                                               selfApplication: selfApp))

        XCTAssertTrue(HexpadAppDelegate.canOpenInDefaultViewer(fileURL: file,
                                                              defaultApplication: otherApp,
                                                              selfApplication: selfApp))

        XCTAssertFalse(HexpadAppDelegate.canOpenInDefaultViewer(fileURL: file,
                                                               defaultApplication: selfApp,
                                                               selfApplication: selfApp),
                       "re-opening the focused file in Hexpad is a no-op")

        // Trailing-slash and symlinked spellings of the same bundle still count.
        XCTAssertFalse(HexpadAppDelegate.canOpenInDefaultViewer(
            fileURL: file,
            defaultApplication: URL(fileURLWithPath: "/Applications/Hexpad.app/"),
            selfApplication: selfApp))

        XCTAssertTrue(HexpadAppDelegate.canOpenInDefaultViewer(fileURL: file,
                                                               defaultApplication: nil,
                                                               selfApplication: selfApp),
                      "an unknown handler stays enabled so the system can report it")
    }
}

// MARK: - View > Tab

/// V19j: Notepad++'s View > Tab navigation. Window keeps Cmd+1..9 for its
/// Tab 1..9 items, so the View leaves are menu-only and the numbered items here
/// must not carry a second copy of those chords.
extension MenuWiringTests {

    private func viewTabMenu() throws -> NSMenu {
        let menu = HexpadAppDelegate().buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let tabItem = try XCTUnwrap(viewMenu.item(withTitle: "Tab"))
        return try XCTUnwrap(tabItem.submenu)
    }

    func testViewMenuTabSubmenuContainsNavigationAndReorderItems() throws {
        let tabMenu = try viewTabMenu()
        let titles = tabMenu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(titles, [
            "1st Tab", "2nd Tab", "3rd Tab", "4th Tab", "5th Tab",
            "6th Tab", "7th Tab", "8th Tab", "9th Tab",
            "First Tab", "Last Tab",
            "Move Tab to Start", "Move Tab to End",
            "Apply Color 1", "Apply Color 2", "Apply Color 3",
            "Apply Color 4", "Apply Color 5", "Remove Color",
        ])

        for (offset, number) in (1...9).enumerated() {
            let item = tabMenu.items[offset]
            XCTAssertEqual(item.tag, number)
            XCTAssertNil(item.target)
            XCTAssertEqual(item.action, #selector(MainWindowController.selectNthTabFromMenu(_:)))
            XCTAssertEqual(item.keyEquivalent, "",
                           "Cmd+\(number) already belongs to Window > Tab \(number)")
        }

        let numbered = tabMenu.items.prefix(9).map(\.tag)
        XCTAssertEqual(numbered, Array(1...9))

        let first = try XCTUnwrap(tabMenu.item(withTitle: "First Tab"))
        XCTAssertEqual(first.action, #selector(MainWindowController.selectFirstTab(_:)))
        XCTAssertNil(first.target)
        let last = try XCTUnwrap(tabMenu.item(withTitle: "Last Tab"))
        XCTAssertEqual(last.action, #selector(MainWindowController.selectLastTab(_:)))
        XCTAssertNil(last.target)

        let moveToStart = try XCTUnwrap(tabMenu.item(withTitle: "Move Tab to Start"))
        XCTAssertEqual(moveToStart.action, #selector(MainWindowController.moveTabToStart(_:)))
        XCTAssertNil(moveToStart.target)
        let moveToEnd = try XCTUnwrap(tabMenu.item(withTitle: "Move Tab to End"))
        XCTAssertEqual(moveToEnd.action, #selector(MainWindowController.moveTabToEnd(_:)))
        XCTAssertNil(moveToEnd.target)
    }

    func testSelectNthTabSelectsTheRightTab() throws {
        let (controller, _) = makeController()
        controller.addNewTab()
        controller.addNewTab()
        XCTAssertEqual(controller.tabStore.count, 3)
        let docs = controller.tabStore.documents

        controller.selectNthTab(0)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[0])

        controller.selectNthTab(2)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[2])

        controller.selectNthTab(1)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[1])

        // Out of range is a no-op, not a crash or a clamp.
        controller.selectNthTab(9)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[1])

        // The action path reads the 1-based tag, like Window > Tab 1..9.
        let item = NSMenuItem(title: "3rd Tab",
                              action: #selector(MainWindowController.selectNthTabFromMenu(_:)),
                              keyEquivalent: "")
        item.tag = 3
        controller.selectNthTabFromMenu(item)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[2])
    }

    func testMoveTabToStartAndEndReorderTheFocusedStore() throws {
        let (controller, _) = makeController()
        controller.addNewTab()
        controller.addNewTab()
        let docs = controller.tabStore.documents

        controller.selectNthTab(2)
        controller.moveTabToStart(nil)
        XCTAssertEqual(controller.tabStore.documents.map(ObjectIdentifier.init),
                       [docs[2], docs[0], docs[1]].map(ObjectIdentifier.init))
        XCTAssertEqual(controller.tabStore.selectedIndex, 0,
                       "the moved tab stays selected at its new slot")
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[2])

        // Already first: enabled in the menu, but a no-op here.
        controller.moveTabToStart(nil)
        XCTAssertEqual(controller.tabStore.documents.map(ObjectIdentifier.init),
                       [docs[2], docs[0], docs[1]].map(ObjectIdentifier.init))

        controller.moveTabToEnd(nil)
        XCTAssertEqual(controller.tabStore.documents.map(ObjectIdentifier.init),
                       [docs[0], docs[1], docs[2]].map(ObjectIdentifier.init))
        XCTAssertEqual(controller.tabStore.selectedIndex, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[2])

        controller.moveTabToEnd(nil)
        XCTAssertEqual(controller.tabStore.documents.map(ObjectIdentifier.init),
                       [docs[0], docs[1], docs[2]].map(ObjectIdentifier.init))
    }

    func testViewTabMenuValidationTracksTabCount() throws {
        let (controller, _) = makeController()

        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let created = NSMenuItem(title: "", action: action, keyEquivalent: "")
            created.tag = tag
            return created
        }
        let nth = { (tag: Int) in item(#selector(MainWindowController.selectNthTabFromMenu(_:)), tag: tag) }
        let first = item(#selector(MainWindowController.selectFirstTab(_:)))
        let last = item(#selector(MainWindowController.selectLastTab(_:)))
        let moveToStart = item(#selector(MainWindowController.moveTabToStart(_:)))
        let moveToEnd = item(#selector(MainWindowController.moveTabToEnd(_:)))

        XCTAssertTrue(controller.validateMenuItem(nth(1)))
        XCTAssertFalse(controller.validateMenuItem(nth(2)), "one tab has no second tab")
        XCTAssertFalse(controller.validateMenuItem(nth(9)))
        XCTAssertFalse(controller.validateMenuItem(first))
        XCTAssertFalse(controller.validateMenuItem(last))
        XCTAssertFalse(controller.validateMenuItem(moveToStart))
        XCTAssertFalse(controller.validateMenuItem(moveToEnd))

        controller.addNewTab()
        XCTAssertTrue(controller.validateMenuItem(nth(2)))
        XCTAssertFalse(controller.validateMenuItem(nth(3)))
        XCTAssertTrue(controller.validateMenuItem(first))
        XCTAssertTrue(controller.validateMenuItem(last))
        // Enabled even though the focused tab may already sit at either edge:
        // the items are applicable, the action is just a no-op.
        XCTAssertTrue(controller.validateMenuItem(moveToStart))
        XCTAssertTrue(controller.validateMenuItem(moveToEnd))
    }

    // MARK: - View > Hide Lines

    func testViewMenuHasHideAndUnhideLinesItems() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)

        let hide = try XCTUnwrap(viewMenu.item(withTitle: "Hide Lines"))
        XCTAssertEqual(hide.action, #selector(MainWindowController.hideLines(_:)))
        XCTAssertNil(hide.target, "validation reaches the controller through the responder chain")

        let unhide = try XCTUnwrap(viewMenu.item(withTitle: "Unhide Lines"))
        XCTAssertEqual(unhide.action, #selector(MainWindowController.unhideLines(_:)))
        XCTAssertNil(unhide.target)

        // Both sit with the folding commands, after the fold-level group and
        // before the zoom block.
        let titles = viewMenu.items.map(\.title)
        let fold = try XCTUnwrap(titles.firstIndex(of: "Unfold Level"))
        XCTAssertEqual(Array(titles[(fold + 1)...(fold + 2)]), ["Hide Lines", "Unhide Lines"])
    }

    func testHideAndUnhideLinesThroughTheController() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "a\nb\nc\nd\n")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let created = NSMenuItem(title: "", action: action, keyEquivalent: "")
            created.tag = tag
            return created
        }
        let hideItem = item(#selector(MainWindowController.hideLines(_:)))
        let unhideItem = item(#selector(MainWindowController.unhideLines(_:)))

        XCTAssertTrue(controller.validateMenuItem(hideItem))
        XCTAssertFalse(controller.validateMenuItem(unhideItem), "nothing is hidden yet")

        // Hide lines 2-3 (the selection covers "b\nc\n").
        textView.setSelectedRange(NSRange(location: 2, length: 4))
        controller.hideLines(nil)

        XCTAssertEqual(doc.editorState.hiddenLinesState.lineRanges, [2...3],
                       "hidden lines persist on the document for the session")
        XCTAssertTrue(controller.validateMenuItem(unhideItem))

        // The rows are excluded from layout: the gutter would render 1, 2, 3.
        // (The empty line after the trailing newline has no fragment of its own,
        // so it never appears in this list.)
        let rows = LineNumberGutter.rows(in: textView,
                                         characterRange: NSRange(location: 0, length: 8))
        XCTAssertEqual(rows.map(\.line), [1, 4],
                       "hidden lines disappear from layout; logical lines keep their identity")
        XCTAssertEqual(doc.editorState.hiddenLinesState.displayNumber(forLine: 4, lineCount: 5), 2,
                       "gutter numbering renumbers the rows after a hidden block")

        // A caret cannot rest inside hidden text: it clamps to the visible
        // line before the block.
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(textView.selectedRange.location, 1)

        // Unhide is targeted at the hidden block next to the caret.
        controller.unhideLines(nil)
        XCTAssertTrue(doc.editorState.hiddenLinesState.isEmpty)
        XCTAssertFalse(controller.validateMenuItem(unhideItem))
        XCTAssertEqual(LineNumberGutter.rows(in: textView,
                                             characterRange: NSRange(location: 0, length: 8)).map(\.line),
                       [1, 2, 3, 4])
    }

    func testSelectingAcrossAHiddenBlockUnhidesIt() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "a\nb\nc\nd\n")
        textView.setSelectedRange(NSRange(location: 2, length: 4))
        controller.hideLines(nil)
        XCTAssertEqual(doc.editorState.hiddenLinesState.lineRanges, [2...3])

        // Selecting the whole buffer covers the hidden span, so the selection
        // observer treats it as "select across to unhide" (N++'s second way).
        textView.setSelectedRange(NSRange(location: 0, length: 8))
        XCTAssertTrue(doc.editorState.hiddenLinesState.isEmpty)
    }

    // MARK: - View > Tab > Colours

    func testViewTabColorItemsAreWiredToOneControllerAction() throws {
        let tabMenu = try viewTabMenu()

        for (offset, color) in (1...TabColorPalette.colorCount).enumerated() {
            let item = try XCTUnwrap(tabMenu.item(withTitle: "Apply Color \(color)"))
            XCTAssertEqual(item.tag, color)
            XCTAssertEqual(item.action, #selector(MainWindowController.applyTabColor(_:)))
            XCTAssertNil(item.target)
            XCTAssertEqual(tabMenu.items.firstIndex(of: item), tabMenu.items.count - 6 + offset)
        }

        let remove = try XCTUnwrap(tabMenu.item(withTitle: "Remove Color"))
        XCTAssertEqual(remove.action, #selector(MainWindowController.removeTabColor(_:)))
        XCTAssertNil(remove.target)
        XCTAssertTrue(tabMenu.items.last === remove)
    }

    func testTabColorApplyRemoveAndValidation() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let created = NSMenuItem(title: "", action: action, keyEquivalent: "")
            created.tag = tag
            return created
        }
        let apply = { (tag: Int) in item(#selector(MainWindowController.applyTabColor(_:)), tag: tag) }
        let remove = item(#selector(MainWindowController.removeTabColor(_:)))

        let firstColor = apply(1)
        XCTAssertTrue(controller.validateMenuItem(firstColor), "Apply only needs a document")
        XCTAssertEqual(firstColor.state, .off)
        XCTAssertFalse(controller.validateMenuItem(remove), "no colour is set")

        let secondColor = apply(2)
        controller.applyTabColor(secondColor)
        XCTAssertEqual(doc.tabColorIndex, 2)

        let current = apply(2)
        XCTAssertTrue(controller.validateMenuItem(current))
        XCTAssertEqual(current.state, .on, "the current colour is checkmarked")
        let other = apply(1)
        XCTAssertTrue(controller.validateMenuItem(other))
        XCTAssertEqual(other.state, .off)
        XCTAssertTrue(controller.validateMenuItem(remove))

        controller.applyTabColor(apply(5))
        XCTAssertEqual(doc.tabColorIndex, 5)

        controller.removeTabColor(nil)
        XCTAssertNil(doc.tabColorIndex)
        XCTAssertFalse(controller.validateMenuItem(remove))
        let cleared = apply(5)
        _ = controller.validateMenuItem(cleared)
        XCTAssertEqual(cleared.state, .off)
    }

    // MARK: - Token styles (Search > Style ...)

    /// The six N++ Search submenus exist, in order, with nil-targeted items
    /// carrying registry identifiers 1-5 (plus All/Clear All where N++ has it).
    func testSearchMenuHasTokenStyleSubmenus() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let search = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)

        let expected: [(title: String, identifiers: [String])] = [
            ("Style All Occurrences of Token",
             TokenStyleState.styleNumbers.map { "style-all-occurrences-\($0)" }),
            ("Style One Token",
             TokenStyleState.styleNumbers.map { "style-one-token-\($0)" }),
            ("Clear Style",
             TokenStyleState.styleNumbers.map { "clear-style-\($0)" } + ["clear-style-all"]),
            ("Jump Up",
             TokenStyleState.styleNumbers.map { "jump-up-\($0)" }),
            ("Jump Down",
             TokenStyleState.styleNumbers.map { "jump-down-\($0)" }),
            ("Copy Styled Text",
             TokenStyleState.styleNumbers.map { "copy-styled-text-\($0)" } + ["copy-styled-text-all"])
        ]

        let titles = search.items.compactMap { $0.submenu?.title }
        XCTAssertEqual(Array(titles.prefix(6)), expected.map(\.title))

        for entry in expected {
            let submenu = try XCTUnwrap(search.item(withTitle: entry.title)?.submenu,
                                        entry.title)
            let items = submenu.items.filter {
                $0.action == #selector(MainWindowController.performTokenStyleCommand(withIdentifier:))
            }
            XCTAssertEqual(items.compactMap { $0.representedObject as? String },
                           entry.identifiers,
                           entry.title)
            for item in items {
                XCTAssertNil(item.target, entry.title)
            }
        }
    }

    /// Style commands need a selection or word at the caret; clear/jump/copy
    /// need the matching style to hold ranges (copy-all only needs text).
    func testTokenStyleMenuValidationTracksSelectionAndStyledRanges() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "alpha beta alpha")
        let textView = controller.allPanes[0].editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        func item(_ identifier: String) -> NSMenuItem {
            let created = NSMenuItem(
                title: identifier,
                action: #selector(MainWindowController.performTokenStyleCommand(withIdentifier:)),
                keyEquivalent: ""
            )
            created.representedObject = identifier
            return created
        }

        XCTAssertTrue(controller.validateMenuItem(item("style-all-occurrences-1")))
        XCTAssertTrue(controller.validateMenuItem(item("style-one-token-1")))
        XCTAssertFalse(controller.validateMenuItem(item("clear-style-1")))
        XCTAssertFalse(controller.validateMenuItem(item("clear-style-all")))
        XCTAssertFalse(controller.validateMenuItem(item("jump-up-1")))
        XCTAssertFalse(controller.validateMenuItem(item("jump-down-1")))
        XCTAssertFalse(controller.validateMenuItem(item("copy-styled-text-1")))
        XCTAssertTrue(controller.validateMenuItem(item("copy-styled-text-all")))

        XCTAssertTrue(controller.performCommand(identifier: "style-all-occurrences-1"))

        XCTAssertTrue(controller.validateMenuItem(item("clear-style-1")))
        XCTAssertTrue(controller.validateMenuItem(item("clear-style-all")))
        XCTAssertTrue(controller.validateMenuItem(item("jump-up-1")))
        XCTAssertTrue(controller.validateMenuItem(item("jump-down-1")))
        XCTAssertTrue(controller.validateMenuItem(item("copy-styled-text-1")))

        XCTAssertTrue(controller.performCommand(identifier: "clear-style-all"))
        XCTAssertFalse(controller.validateMenuItem(item("clear-style-1")))
        XCTAssertFalse(controller.validateMenuItem(item("clear-style-all")))
    }

    /// A style command must leave persistent background marks on exactly the
    /// styled ranges, and those marks must not live in text storage (the syntax
    /// highlighter rewrites it).
    func testStyleCommandRendersTemporaryAttributesOnStyledRanges() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "alpha beta alpha")
        let editor = controller.allPanes[0].editor
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        XCTAssertTrue(controller.performCommand(identifier: "style-all-occurrences-2"))
        XCTAssertEqual(doc.editorState.tokenStyleState.ranges(for: 2).map(\.location),
                       [0, 11])
        XCTAssertEqual(textView.tokenStyleState.ranges(for: 2).map(\.location),
                       [0, 11])

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let storage = try XCTUnwrap(textView.textStorage)

        // Simulate the highlighter's viewport rewrite and the FindBar's
        // background-only clear; the token marks use a private key.
        storage.setAttributes([.font: NSFont.systemFont(ofSize: 12)],
                              range: NSRange(location: 0, length: storage.length))
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                               forCharacterRange: NSRange(location: 0,
                                                                          length: storage.length))

        for location in [0, 11] {
            XCTAssertNotNil(layoutManager.temporaryAttribute(
                MultiCaretTextView.tokenStyleAttribute,
                atCharacterIndex: location,
                effectiveRange: nil
            ), "styled range at \(location) lost its mark")
        }
        XCTAssertNil(layoutManager.temporaryAttribute(
            MultiCaretTextView.tokenStyleAttribute,
            atCharacterIndex: 6,
            effectiveRange: nil
        ))
    }
}

// MARK: - V19e: Always on Top / Post-It / Distraction Free

/// Window-mode wiring. Frame math, checkmarks and mutual exclusion are covered
/// here. The actual NSWindow full-screen transition and the on-screen floating
/// level are window-server behaviours and are deliberately not asserted beyond
/// the level property; they need a visible window.
extension MenuWiringTests {

    private func modeValidationItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "mode", action: action, keyEquivalent: "")
    }

    private func statusBar(of controller: MainWindowController) throws -> StatusBar {
        try XCTUnwrap(controller.statusBar)
    }

    func testViewMenuHasWindowModeItems() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)

        let expected: [(title: String, action: Selector)] = [
            ("Always on Top", #selector(MainWindowController.toggleAlwaysOnTop(_:))),
            ("Post-It", #selector(MainWindowController.togglePostIt(_:))),
            ("Distraction Free Mode", #selector(MainWindowController.toggleDistractionFreeMode(_:)))
        ]

        for entry in expected {
            let item = try XCTUnwrap(viewMenu.item(withTitle: entry.title), entry.title)
            XCTAssertEqual(item.action, entry.action, entry.title)
            XCTAssertNil(item.target, "validation reaches the controller through the responder chain")
            XCTAssertEqual(item.keyEquivalent, "", "menu-only: no Windows-only or F-key chord")
            XCTAssertNil(item.submenu)
        }

        // The block sits after the zoom group, before split view.
        let titles = viewMenu.items.map(\.title)
        let resetZoom = try XCTUnwrap(titles.firstIndex(of: "Reset Zoom"))
        XCTAssertEqual(Array(titles[(resetZoom + 1)...(resetZoom + 4)]),
                       ["", "Always on Top", "Post-It", "Distraction Free Mode"])
    }

    func testAlwaysOnTopTogglesWindowLevelAndCheckmark() throws {
        let (controller, window) = makeController()
        let item = modeValidationItem(#selector(MainWindowController.toggleAlwaysOnTop(_:)))

        XCTAssertFalse(controller.isAlwaysOnTop)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)

        controller.toggleAlwaysOnTop(nil)
        XCTAssertTrue(controller.isAlwaysOnTop)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)

        controller.toggleAlwaysOnTop(nil)
        XCTAssertFalse(controller.isAlwaysOnTop)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    func testPostItHidesChromeKeepsFrameAndRestoresExactly() throws {
        let (controller, window) = makeController()
        let pane = controller.allPanes[0]
        let status = try statusBar(of: controller)
        let originalFrame = window.frame
        let originalToolbar = try XCTUnwrap(window.toolbar)

        XCTAssertFalse(pane.tabScrollView.isHidden)
        XCTAssertFalse(status.isHidden)

        controller.togglePostIt(nil)
        // The window's content frame settles on the next layout pass (the
        // toolbar removal resizes it first); force that pass before reading
        // frame math, exactly like a visible window's display cycle.
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .postIt)
        XCTAssertEqual(window.frame, originalFrame, "Post-It keeps the window size and position")
        XCTAssertNil(window.toolbar, "toolbar is removed while in Post-It")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))

        XCTAssertTrue(pane.tabScrollView.isHidden)
        XCTAssertEqual(pane.tabScrollView.frame, .zero, "the tab bar reserves no layout slot")
        XCTAssertTrue(status.isHidden)
        XCTAssertEqual(status.frame, .zero)

        let bounds = controller.view.bounds
        XCTAssertEqual(pane.editor.frame.minY, 0, accuracy: 0.5, "status bar slot collapsed")
        XCTAssertEqual(pane.editor.frame.maxY, bounds.height, accuracy: 0.5, "tab bar slot collapsed")
        XCTAssertEqual(pane.editor.frame.width, bounds.width, accuracy: 0.5)

        controller.togglePostIt(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .normal)
        XCTAssertTrue(window.toolbar === originalToolbar, "the same toolbar object comes back")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(pane.tabScrollView.isHidden)
        XCTAssertEqual(pane.tabScrollView.frame.height, 32, accuracy: 0.5)
        XCTAssertFalse(pane.tabBar.isHidden)
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(status.frame.height, 22, accuracy: 0.5)
        XCTAssertEqual(pane.editor.frame.minY, 22, accuracy: 0.5)
        // The restored toolbar means the content area is smaller than the
        // window frame again, so read the settled bounds rather than the
        // Post-It-mode snapshot above.
        XCTAssertEqual(pane.editor.frame.maxY,
                       controller.view.bounds.height - 32, accuracy: 0.5)
    }

    func testPostItEscapeExitsTheMode() throws {
        let (controller, window) = makeController()
        let originalToolbar = try XCTUnwrap(window.toolbar)

        controller.togglePostIt(nil)
        XCTAssertEqual(controller.chromeMode, .postIt)

        // Escape reaches the controller as cancelOperation once no inner
        // responder (find bar, incremental search, multi-caret) consumed it.
        controller.cancelOperation(nil)
        XCTAssertEqual(controller.chromeMode, .normal)
        XCTAssertTrue(window.toolbar === originalToolbar)
    }

    func testDistractionFreeHidesChromeAndWidensMargins() throws {
        let (controller, _) = makeController()
        let pane = controller.allPanes[0]
        let status = try statusBar(of: controller)

        controller.toggleDistractionFreeMode(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .distractionFree)

        let bounds = controller.view.bounds
        let inset = floor(bounds.width * 0.15)
        XCTAssertTrue(pane.tabScrollView.isHidden)
        XCTAssertEqual(pane.tabScrollView.frame, .zero)
        XCTAssertTrue(status.isHidden)
        XCTAssertEqual(status.frame, .zero)
        XCTAssertEqual(pane.editor.frame.minX, inset, accuracy: 0.5)
        XCTAssertEqual(pane.editor.frame.width, bounds.width - inset * 2, accuracy: 0.5)
        XCTAssertEqual(pane.editor.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(pane.editor.frame.maxY, bounds.height, accuracy: 0.5)

        controller.toggleDistractionFreeMode(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .normal)
        XCTAssertFalse(pane.tabScrollView.isHidden)
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(pane.editor.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(pane.editor.frame.width, bounds.width, accuracy: 0.5)
    }

    func testWindowsModesAreMutuallyExclusive() throws {
        let (controller, window) = makeController()
        let pane = controller.allPanes[0]
        let originalToolbar = try XCTUnwrap(window.toolbar)

        controller.togglePostIt(nil)
        XCTAssertEqual(controller.chromeMode, .postIt)

        // Entering Distraction Free leaves Post-It first and restores its chrome.
        controller.toggleDistractionFreeMode(nil)
        XCTAssertEqual(controller.chromeMode, .distractionFree)
        XCTAssertTrue(window.toolbar === originalToolbar, "Post-It chrome was restored on exit")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))

        // Entering Post-It from Distraction Free leaves full screen first.
        controller.togglePostIt(nil)
        XCTAssertEqual(controller.chromeMode, .postIt)
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(pane.tabScrollView.isHidden)
    }

    func testWindowModeValidationCheckmarksReflectMode() throws {
        let (controller, _) = makeController()
        let always = modeValidationItem(#selector(MainWindowController.toggleAlwaysOnTop(_:)))
        let postIt = modeValidationItem(#selector(MainWindowController.togglePostIt(_:)))
        let distractionFree = modeValidationItem(#selector(MainWindowController.toggleDistractionFreeMode(_:)))

        for item in [always, postIt, distractionFree] {
            XCTAssertTrue(controller.validateMenuItem(item))
            XCTAssertEqual(item.state, .off)
        }

        controller.toggleAlwaysOnTop(nil)
        XCTAssertTrue(controller.validateMenuItem(always))
        XCTAssertEqual(always.state, .on)

        controller.togglePostIt(nil)
        XCTAssertTrue(controller.validateMenuItem(postIt))
        XCTAssertEqual(postIt.state, .on)
        XCTAssertTrue(controller.validateMenuItem(distractionFree))
        XCTAssertEqual(distractionFree.state, .off)

        controller.toggleDistractionFreeMode(nil)
        XCTAssertTrue(controller.validateMenuItem(distractionFree))
        XCTAssertEqual(distractionFree.state, .on)
        XCTAssertTrue(controller.validateMenuItem(postIt))
        XCTAssertEqual(postIt.state, .off, "entering one mode clears the other's checkmark")
    }
}

// MARK: - V19b: Fold Current Level / Fold Level 1...8

extension MenuWiringTests {

    private func foldCommandMenu() throws -> NSMenu {
        let menu = HexpadAppDelegate().buildMainMenu()
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        return viewMenu
    }

    func testViewMenuHasFoldCurrentLevelItems() throws {
        let viewMenu = try foldCommandMenu()

        let foldCurrent = try XCTUnwrap(viewMenu.item(withTitle: "Fold Current Level"))
        XCTAssertEqual(foldCurrent.representedObject as? String, "fold-current-level")
        XCTAssertEqual(foldCurrent.action, #selector(MainWindowController.foldCurrentLevel(_:)))
        XCTAssertNil(foldCurrent.target, "validation reaches the controller through the responder chain")

        let unfoldCurrent = try XCTUnwrap(viewMenu.item(withTitle: "Unfold Current Level"))
        XCTAssertEqual(unfoldCurrent.representedObject as? String, "unfold-current-level")
        XCTAssertEqual(unfoldCurrent.action, #selector(MainWindowController.unfoldCurrentLevel(_:)))
        XCTAssertNil(unfoldCurrent.target)
    }

    func testViewMenuHasFoldAndUnfoldLevelSubmenusWithAllEightLevels() throws {
        let viewMenu = try foldCommandMenu()

        let foldLevel = try XCTUnwrap(viewMenu.item(withTitle: "Fold Level"))
        let foldMenu = try XCTUnwrap(foldLevel.submenu)
        XCTAssertEqual(foldMenu.items.map(\.title), (1...8).map { "Fold Level \($0)" })
        for (offset, level) in (1...8).enumerated() {
            let item = foldMenu.items[offset]
            XCTAssertEqual(item.tag, level)
            XCTAssertEqual(item.representedObject as? String, "fold-level-\(level)")
            XCTAssertEqual(item.action, #selector(MainWindowController.foldLevel(_:)))
            XCTAssertNil(item.target)
            XCTAssertEqual(item.keyEquivalent, "", "level commands are menu-only by default")
        }

        let unfoldLevel = try XCTUnwrap(viewMenu.item(withTitle: "Unfold Level"))
        let unfoldMenu = try XCTUnwrap(unfoldLevel.submenu)
        XCTAssertEqual(unfoldMenu.items.map(\.title), (1...8).map { "Unfold Level \($0)" })
        for (offset, level) in (1...8).enumerated() {
            let item = unfoldMenu.items[offset]
            XCTAssertEqual(item.tag, level)
            XCTAssertEqual(item.representedObject as? String, "unfold-level-\(level)")
            XCTAssertEqual(item.action, #selector(MainWindowController.unfoldLevel(_:)))
            XCTAssertNil(item.target)
        }
    }

    /// All 18 new identifiers are registry commands, so menus, macros and the
    /// validation path agree on their names.
    func testFoldLevelMenuIdentifiersAreRegisteredCommands() throws {
        let registry = CommandRegistry.default
        let identifiers = ["fold-current-level", "unfold-current-level"]
            + (1...8).map { "fold-level-\($0)" }
            + (1...8).map { "unfold-level-\($0)" }

        XCTAssertEqual(identifiers.count, 18)
        for identifier in identifiers {
            XCTAssertNotNil(registry.command(for: identifier), identifier)
        }

        let viewMenu = try foldCommandMenu()
        let represented = viewMenu.items.compactMap { $0.representedObject as? String }
            + viewMenu.items.flatMap { $0.submenu?.items.compactMap { $0.representedObject as? String } ?? [] }
        for identifier in identifiers {
            XCTAssertTrue(represented.contains(identifier), identifier)
        }
    }

    /// Fold-level commands follow Fold All's validation: enabled only with an
    /// open document that has at least one foldable range.
    func testFoldLevelCommandsValidateLikeFoldAll() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let created = NSMenuItem(title: "", action: action, keyEquivalent: "")
            created.tag = tag
            return created
        }

        let current = item(#selector(MainWindowController.foldCurrentLevel(_:)))
        let unfoldCurrent = item(#selector(MainWindowController.unfoldCurrentLevel(_:)))
        let level2 = item(#selector(MainWindowController.foldLevel(_:)), tag: 2)
        let unfold4 = item(#selector(MainWindowController.unfoldLevel(_:)), tag: 4)

        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: "outer {\n    inner {\n        x\n    }\n}\n")
        controller.updateEditor()

        XCTAssertTrue(controller.validateMenuItem(current))
        XCTAssertTrue(controller.validateMenuItem(unfoldCurrent))
        XCTAssertTrue(controller.validateMenuItem(level2))
        XCTAssertTrue(controller.validateMenuItem(unfold4))

        doc.replaceAllText(with: "plain text")
        XCTAssertFalse(controller.validateMenuItem(current), "no foldable ranges")
        XCTAssertFalse(controller.validateMenuItem(level2))

        // No document at all disables every fold-level item.
        doc.replaceAllText(with: "outer {\n    x\n}\n")
        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(current))
        XCTAssertFalse(controller.validateMenuItem(level2))
    }

    /// The selector routes the item tag to the matching registry identifier
    /// and folds only that nesting level.
    func testFoldLevelMenuItemRoutesDepthAndFoldsOnlyThatLevel() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        let text = "outer {\n    inner {\n        x\n    }\n}\n"
        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: text)
        controller.updateEditor()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let item = NSMenuItem(title: "Fold Level 2",
                              action: #selector(MainWindowController.foldLevel(_:)),
                              keyEquivalent: "")
        item.tag = 2
        controller.foldLevel(item)

        let collapsed = doc.foldState.collapsedRanges
        XCTAssertEqual(collapsed.count, 1, "only the depth-2 fold is collapsed")
        XCTAssertEqual(collapsed.map(\.location).first,
                       ((text as NSString).range(of: "inner {").location
                        + "inner ".utf16.count),
                       "the fold range starts at the open brace")

        let unfoldItem = NSMenuItem(title: "Unfold Level 2",
                                    action: #selector(MainWindowController.unfoldLevel(_:)),
                                    keyEquivalent: "")
        unfoldItem.tag = 2
        controller.unfoldLevel(unfoldItem)
        XCTAssertTrue(doc.foldState.collapsedRanges.isEmpty)
    }
}
