import XCTest
import AppKit
@testable import Hexpad
@testable import HexpadKit

// MARK: - Shortcut Mapper (Wave 4B)

final class ShortcutMapperTests: XCTestCase {

    func testRegistryFallbackListsCommandsWithChords() {
        // No menu: pure registry + KeybindingStore walk.
        let entries = ShortcutMapperModel.entries(menu: nil)
        XCTAssertFalse(entries.isEmpty, "registry fallback lists the core commands")
        for entry in entries where entry.identifier != nil {
            XCTAssertFalse(entry.chord.isEmpty, "bound command \(entry.title) shows a chord")
        }
        XCTAssertTrue(entries.contains { $0.title.contains("Bookmark") },
                      "core command present in the mapper")
    }

    func testFilteredModelNarrowsRows() {
        let all = ShortcutMapperModel.entries(menu: nil)
        XCTAssertFalse(all.isEmpty)
        let none = ShortcutMapperModel.filtered(all, query: "zzz-no-match-zzz")
        XCTAssertTrue(none.isEmpty, "no rows match nonsense")
        let narrowed = ShortcutMapperModel.filtered(all, query: "bookmark")
        XCTAssertFalse(narrowed.isEmpty)
        XCTAssertTrue(narrowed.count < all.count, "filter narrows")
    }

    func testWindowBasics() {
        let controller = ShortcutMapperWindowController()
        XCTAssertEqual(controller.window?.title, "Shortcut Mapper")
        XCTAssertEqual(controller.window?.isReleasedWhenClosed, false,
                       "reused for the app's lifetime, like Preferences")
        XCTAssertEqual(controller.visibleEntries.count, controller.allEntries.count,
                       "empty query shows everything")
    }

    func testAppMenuPlacementAdjacentToPreferences() {
        let delegate = HexpadAppDelegate()
        let menu = delegate.buildMainMenu()
        guard let appMenu = menu.item(at: 0)?.submenu else { return XCTFail("no app menu") }
        let titles = appMenu.items.map(\.title)
        // AppKit renames "Preferences…" to "Settings…" on macOS 13+; locate
        // the standard slot by key equivalent (the PreferencesTests pattern).
        guard let prefIndex = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else {
            return XCTFail("Preferences item missing")
        }
        XCTAssertTrue(["Preferences…", "Settings…"].contains(appMenu.items[prefIndex].title))
        let next = appMenu.items[min(prefIndex + 1, titles.count - 1)]
        XCTAssertTrue(next.title.contains("Shortcut Mapper"),
                      "Shortcut Mapper sits next to Preferences, got \(titles)")
        XCTAssertEqual(next.keyEquivalent, "", "no chord (⌘, stays Preferences)")
        XCTAssertTrue(next.target === delegate, "delegate-targeted like its neighbors")
    }

    // MARK: - Dedupe

    func testDedupeKeepsChordBearingRowOverNone() {
        // Mirrors the real menus: the Keybindings submenu carries the command
        // identifier but no key equivalent, while the Text menu row carries
        // the chord. The None row is walked first to prove order does not
        // decide which row survives.
        let action = #selector(MainWindowController.performCommand(withIdentifier:))
        let root = NSMenu(title: "Root")
        let keybindingsMenu = NSMenu(title: "Keybindings")
        let noneRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "")
        noneRow.representedObject = "delete-line"
        keybindingsMenu.addItem(noneRow)
        let keybindingsItem = NSMenuItem(title: "Keybindings", action: nil, keyEquivalent: "")
        keybindingsItem.submenu = keybindingsMenu
        root.addItem(keybindingsItem)

        let textRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "d")
        textRow.keyEquivalentModifierMask = [.command, .shift]
        textRow.representedObject = "delete-line"
        root.addItem(textRow)

        let entries = ShortcutMapperModel.entries(menu: root)
        let deleteRows = entries.filter { $0.identifier == "delete-line" }
        XCTAssertEqual(deleteRows.count, 1, "one row per command identifier")
        XCTAssertEqual(deleteRows.first?.chord, "⇧⌘D",
                       "the chord-bearing menu row beats the Keybindings None row")
        XCTAssertEqual(deleteRows.first?.title, "Delete Line",
                       "the surviving row keeps the chord-bearing row's title")

        // The surviving row is what search filters over.
        XCTAssertEqual(ShortcutMapperModel.filtered(entries, query: "Delete Line").count, 1)
        XCTAssertEqual(ShortcutMapperModel.filtered(entries, query: "⇧⌘D").count, 1)
    }

    func testDedupeUpgradesLoneNoneRowFromRegistry() {
        // A command whose only menu row is the Keybindings submenu's "None"
        // row still shows its resolved chord from the registry.
        let action = #selector(MainWindowController.performCommand(withIdentifier:))
        let root = NSMenu(title: "Root")
        let noneRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "")
        noneRow.representedObject = "delete-line"
        root.addItem(noneRow)

        let entries = ShortcutMapperModel.entries(menu: root)
        let deleteRows = entries.filter { $0.identifier == "delete-line" }
        XCTAssertEqual(deleteRows.count, 1)
        XCTAssertEqual(deleteRows.first?.chord,
                       KeybindingStore.displayString(for: KeybindingStore.resolvedBinding(for: "delete-line")))
    }

    func testDedupeKeepsRowsWithSharedNonCommandIdentifier() {
        // Window > Sort By reuses one representedObject key ("name") for the
        // ascending and descending rows, with `tag` telling them apart. Dedupe
        // is by command identifier only, so those rows must all survive.
        let action = #selector(MainWindowController.sortDocumentsBy(_:))
        let root = NSMenu(title: "Root")
        let ascending = NSMenuItem(title: "Name (Ascending)", action: action, keyEquivalent: "")
        ascending.representedObject = TabSortKey.name.rawValue
        ascending.tag = 1
        let descending = NSMenuItem(title: "Name (Descending)", action: action, keyEquivalent: "")
        descending.representedObject = TabSortKey.name.rawValue
        descending.tag = 0
        root.addItem(ascending)
        root.addItem(descending)

        let entries = ShortcutMapperModel.entries(menu: root)
        let sortRows = entries.filter { $0.title.hasPrefix("Name (") }
        XCTAssertEqual(sortRows.count, 2, "distinct rows sharing a non-command identifier both survive")
    }

    func testDedupeKeepsLoneUnregisteredRow() {
        // An item whose representedObject names something that is not a
        // registry command (here: a free-form app menu payload) must survive
        // collection even though it has no registry chord to upgrade to.
        let action = #selector(MainWindowController.performCommand(withIdentifier:))
        let root = NSMenu(title: "Root")
        let specialRow = NSMenuItem(title: "Special Action", action: action, keyEquivalent: "s")
        // Bare "S" chord: AppKit defaults keyEquivalentModifierMask to .command,
        // so an unset mask would display "⌘S". The intent here is an unmodified
        // key, so clear the mask explicitly.
        specialRow.keyEquivalentModifierMask = []
        specialRow.representedObject = "not-a-registry-command"
        root.addItem(specialRow)

        let entries = ShortcutMapperModel.entries(menu: root)
        let specialRows = entries.filter { $0.title == "Special Action" }
        XCTAssertEqual(specialRows.count, 1, "unregistered payloads are not deduped away")
        XCTAssertEqual(specialRows.first?.chord, "S",
                       "unregistered row keeps its own chord")
    }

    func testDedupeCollapsesDuplicateMenuRowsWithSameChord() {
        // The same command can be carried by more than one menu row that both
        // already carry a chord; when the rows agree there is nothing to
        // upgrade, so the walk must still keep a single row.
        let action = #selector(MainWindowController.performCommand(withIdentifier:))
        let root = NSMenu(title: "Root")
        let firstRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "d")
        firstRow.keyEquivalentModifierMask = [.command, .shift]
        firstRow.representedObject = "delete-line"
        root.addItem(firstRow)
        let secondRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "d")
        secondRow.keyEquivalentModifierMask = [.command, .shift]
        secondRow.representedObject = "delete-line"
        root.addItem(secondRow)

        let entries = ShortcutMapperModel.entries(menu: root)
        let deleteRows = entries.filter { $0.identifier == "delete-line" }
        XCTAssertEqual(deleteRows.count, 1, "same-chord duplicates collapse to one row")
        XCTAssertEqual(deleteRows.first?.chord, "⇧⌘D",
                       "the surviving row keeps the shared chord")
    }

    func testFilteredStillFindsDedupedCommandByTitleChordAndIdentifier() {
        // After dedupe, exactly one row exists per command identifier; the
        // search must still find that row through every supported field.
        let action = #selector(MainWindowController.performCommand(withIdentifier:))
        let root = NSMenu(title: "Root")
        let keybindingsMenu = NSMenu(title: "Keybindings")
        let noneRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "")
        noneRow.representedObject = "delete-line"
        keybindingsMenu.addItem(noneRow)
        let keybindingsItem = NSMenuItem(title: "Keybindings", action: nil, keyEquivalent: "")
        keybindingsItem.submenu = keybindingsMenu
        root.addItem(keybindingsItem)
        let textRow = NSMenuItem(title: "Delete Line", action: action, keyEquivalent: "d")
        textRow.keyEquivalentModifierMask = [.command, .shift]
        textRow.representedObject = "delete-line"
        root.addItem(textRow)

        let entries = ShortcutMapperModel.entries(menu: root)
        XCTAssertEqual(entries.filter { $0.identifier == "delete-line" }.count, 1)

        XCTAssertEqual(ShortcutMapperModel.filtered(entries, query: "Delete Line").count, 1,
                       "title search finds the deduped row")
        XCTAssertEqual(ShortcutMapperModel.filtered(entries, query: "⇧⌘D").count, 1,
                       "chord search finds the deduped row")
        XCTAssertEqual(ShortcutMapperModel.filtered(entries, query: "delete-line").count, 1,
                       "identifier search finds the deduped row")
    }

    func testDedupeKeepsLoneNoneRowWithoutRegistryChord() {
        // A command whose only menu row is an unbound ("None") row and which
        // has no registry chord to upgrade to must keep its row rather than
        // being dropped or swapped out.
        let action = #selector(MainWindowController.performCommand(withIdentifier:))
        let root = NSMenu(title: "Root")
        let noneRow = NSMenuItem(title: "Standalone Action", action: action, keyEquivalent: "")
        noneRow.representedObject = "not-a-registry-command"
        root.addItem(noneRow)

        let entries = ShortcutMapperModel.entries(menu: root)
        let standaloneRows = entries.filter { $0.title == "Standalone Action" }
        XCTAssertEqual(standaloneRows.count, 1, "unregistered None row keeps its row")
        XCTAssertEqual(standaloneRows.first?.chord, "None",
                       "unregistered None row stays unbound")
    }
}

// MARK: - New Window = New Instance (Wave 4B)

final class NewInstanceWindowTests: XCTestCase {

    func testNewWindowMakesIndependentController() {
        let delegate = HexpadAppDelegate()
        delegate.newWindow()
        defer { delegate.closeAllAdditionalWindowsForTest() }
        let additional = delegate.additionalWindowControllersForTest
        XCTAssertEqual(additional.count, 1, "one additional window")
        let controller = try! XCTUnwrap(additional.first)
        XCTAssertTrue(controller.isAdditionalWindow)
        XCTAssertEqual(controller.tabStore.count, 1, "fresh untitled doc")
        XCTAssertNil(controller.tabStore.selectedDocument?.filePath)
    }

    func testNewWindowDoesNotInheritTabs() {
        let delegate = HexpadAppDelegate()
        let docA = DocumentModel(text: "A", filePath: nil)
        let docB = DocumentModel(text: "B", filePath: nil)
        delegate.activeController?.tabStore.documents = [docA, docB]
        delegate.newWindow()
        defer { delegate.closeAllAdditionalWindowsForTest() }
        let additional = delegate.additionalWindowControllersForTest
        XCTAssertEqual(additional.first?.tabStore.count, 1,
                       "new window starts empty, not inheriting")
        XCTAssertFalse(additional.first!.tabStore.documents.contains { $0 === docA || $0 === docB })
    }
}

// MARK: - Clone to Other View (Wave 4B)

final class CloneToOtherViewTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    func testCloneAddsIndependentTabInOtherGroup() throws {
        let controller = makeController()
        controller.openSplitView()
        let original = DocumentModel(text: "clone me\n",
                                     filePath: URL(fileURLWithPath: "/tmp/clone-test.txt"))
        original.tabColorIndex = 2
        original.setReadOnly(true)
        original.setModified(true)
        controller.tabStore.documents = [original]
        controller.tabStore.selectedIndex = 0
        let primaryStore = controller.tabStore // focus-following: capture before clone focuses the receiving group

        controller.cloneDocumentToOtherView(nil)

        let secondary = try XCTUnwrap(controller.allPanes.first { $0.group == .secondary }?.tabStore)
        XCTAssertEqual(secondary.count, 1, "clone lands in the other group")
        let clone = try XCTUnwrap(secondary.documents.first)
        XCTAssertNotIdentical(clone, original, "independent buffer")
        XCTAssertNotEqual(clone.id, original.id)
        XCTAssertEqual(clone.text, "clone me\n", "same content")
        XCTAssertEqual(clone.filePath, original.filePath, "same file")
        XCTAssertEqual(clone.tabColorIndex, 2, "per-doc state copies")
        XCTAssertTrue(clone.isReadOnly, "read-only copies")
        XCTAssertTrue(clone.unsavedChanges, "dirty copies")
        XCTAssertEqual(clone.caretRange.location, 0, "caret resets")
        XCTAssertEqual(primaryStore.count, 1, "original stays put")
        XCTAssertIdentical(primaryStore.documents.first, original)
    }

    func testCloneRequiresSplit() {
        let controller = makeController()
        let doc = DocumentModel(text: "solo")
        controller.tabStore.documents = [doc]
        controller.cloneDocumentToOtherView(nil)
        XCTAssertEqual(controller.tabStore.count, 1, "no split = no clone")
        XCTAssertEqual(controller.allPanes.count, 1, "no second group created by clone")
    }

    func testContextMenuListsCloneOnlyWhenSplitOpen() {
        let controller = makeController()
        let doc = DocumentModel(text: "x")
        controller.tabStore.documents = [doc]
        let closedMenu = controller.buildTabContextMenu(for: 0)
        XCTAssertFalse(closedMenu.items.contains { $0.title == "Clone to Other View" },
                       "hidden while split closed (pinned contract)")
        controller.openSplitView()
        let openMenu = controller.buildTabContextMenu(for: 0)
        let moveIndex = openMenu.items.firstIndex { $0.title == "Move to Other View" }
        let cloneIndex = openMenu.items.firstIndex { $0.title == "Clone to Other View" }
        XCTAssertNotNil(cloneIndex, "present while split open")
        XCTAssertEqual(cloneIndex!, moveIndex! + 1, "sits right after Move")
    }
}

// MARK: - Print header/footer (Wave 4B — verify + pin; pre-existed in 3b274ca)

final class PrintHeaderFooterTests: XCTestCase {

    func testHeaderShowsPathWhenItFits() {
        let view = PrintDocumentView(text: "x\n",
                                     font: NSFont.systemFont(ofSize: 12),
                                     fileName: "notes.txt",
                                     filePath: "/Users/test/notes.txt")
        XCTAssertEqual(view.headerText, "notes.txt   —   /Users/test/notes.txt")
    }

    func testHeaderFallsBackToNameWithoutPath() {
        let view = PrintDocumentView(text: "x\n",
                                     font: NSFont.systemFont(ofSize: 12),
                                     fileName: "Untitled",
                                     filePath: nil)
        XCTAssertEqual(view.headerText, "Untitled", "no-path fallback")
    }

    func testFooterCountsPages() throws {
        let view = PrintDocumentView(text: String(repeating: "line\n", count: 200),
                                     font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                     fileName: "notes.txt",
                                     filePath: nil)
        var range = NSRange(location: 1, length: 0)
        _ = view.knowsPageRange(&range)
        let pages = view.pageCountForTest
        XCTAssertGreaterThanOrEqual(pages, 2, "200 lines paginate")
        XCTAssertEqual(view.footerText(pageIndex: 0), "Page 1 of \(pages)")
        XCTAssertEqual(view.footerText(pageIndex: pages - 1), "Page \(pages) of \(pages)")
    }
}
