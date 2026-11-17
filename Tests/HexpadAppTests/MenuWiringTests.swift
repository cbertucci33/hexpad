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

        // A caret on the first line can duplicate/delete/comment, but cannot
        // move up or change case.
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("duplicate-line")))
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("delete-line")))
        XCTAssertTrue(controller.validateMenuItem(commandValidationItem("toggle-line-comment")))
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
}
