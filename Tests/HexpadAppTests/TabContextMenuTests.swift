import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19l: the tab right-click context menu. Structure and targets are inspected
/// on the real menu the controller builds; validation is driven by calling the
/// two NSMenuItemValidation owners directly, as MenuWiringTests does.
final class TabContextMenuTests: XCTestCase {

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func tabButtons(in bar: TabBarView) -> [TabButton] {
        bar.subviews.compactMap { $0 as? TabButton }
    }

    /// A full right-click gesture. The button's action mask is leftMouseUp
    /// only, so the rightMouseUp must not select a second time.
    private func rightClick(_ button: TabButton) {
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let down = NSEvent.mouseEvent(with: .rightMouseDown,
                                      location: point,
                                      modifierFlags: [],
                                      timestamp: 0,
                                      windowNumber: 0,
                                      context: nil,
                                      eventNumber: 0,
                                      clickCount: 1,
                                      pressure: 0)!
        button.rightMouseDown(with: down)
        let up = NSEvent.mouseEvent(with: .rightMouseUp,
                                    location: point,
                                    modifierFlags: [],
                                    timestamp: 0,
                                    windowNumber: 0,
                                    context: nil,
                                    eventNumber: 0,
                                    clickCount: 1,
                                    pressure: 0)!
        button.rightMouseUp(with: up)
    }

    // MARK: - Structure

    func testContextMenuHasExpectedTitlesOrderAndTargets() {
        let (controller, _) = makeController()
        let delegate = HexpadAppDelegate()
        let menu = controller.buildTabContextMenu(for: 0, delegate: delegate)

        XCTAssertEqual(menu.items.map(\.title), [
            "Close Tab", "Close All Tabs", "Close All but Active Document",
            "Close All to the Left", "Close All to the Right", "Close All Unchanged",
            "",
            "Save", "Save As...", "Reload from Disk", "Print…",
            "",
            "Open Containing Folder",
            "",
            "Move to Other View", "Move Tab to Start", "Move Tab to End",
        ])
        XCTAssertEqual(menu.items.indices.filter { menu.items[$0].isSeparatorItem }, [6, 11, 13])

        // Delegate commands keep the File menu's explicit target so close-scope
        // validation reaches HexpadAppDelegate.validateMenuItem.
        let delegateActions: [(String, Selector)] = [
            ("Close Tab", #selector(HexpadAppDelegate.closeTab)),
            ("Close All Tabs", #selector(HexpadAppDelegate.closeAllTabs)),
            ("Close All but Active Document", #selector(HexpadAppDelegate.closeAllButActiveDocument)),
            ("Close All to the Left", #selector(HexpadAppDelegate.closeAllDocumentsToLeft)),
            ("Close All to the Right", #selector(HexpadAppDelegate.closeAllDocumentsToRight)),
            ("Close All Unchanged", #selector(HexpadAppDelegate.closeAllUnchangedDocuments)),
            ("Save", #selector(HexpadAppDelegate.saveFile)),
            ("Save As...", #selector(HexpadAppDelegate.saveAsFile)),
        ]
        for (title, action) in delegateActions {
            let item = menu.item(withTitle: title)
            XCTAssertTrue(item?.target === delegate, "\(title) targets the delegate")
            XCTAssertEqual(item?.action, action, title)
        }

        // Controller commands stay nil-targeted, exactly like File/View.
        let responderActions: [(String, Selector)] = [
            ("Reload from Disk", #selector(MainWindowController.reloadActiveDocument(_:))),
            ("Print…", #selector(MainWindowController.printDocument(_:))),
            ("Move to Other View", #selector(MainWindowController.moveToOtherView(_:))),
            ("Move Tab to Start", #selector(MainWindowController.moveTabToStart(_:))),
            ("Move Tab to End", #selector(MainWindowController.moveTabToEnd(_:))),
        ]
        for (title, action) in responderActions {
            let item = menu.item(withTitle: title)
            XCTAssertNil(item?.target, "\(title) resolves through the responder chain")
            XCTAssertEqual(item?.action, action, title)
        }

        // The not-yet-shipped N++ commands must not leak into this slice.
        let titles = menu.items.map(\.title)
        for absent in ["Rename", "Save a Copy As", "Move to Recycle Bin",
                       "Move to New Instance", "Clone to Other View",
                       "Read-Only", "Sort By"] {
            XCTAssertFalse(titles.contains(absent), "\(absent) belongs to a later slice")
        }
    }

    func testOpenContainingFolderSubmenuMatchesFileMenu() {
        let (controller, _) = makeController()
        let menu = controller.buildTabContextMenu(for: 0)

        let containing = menu.item(withTitle: "Open Containing Folder")
        XCTAssertNotNil(containing?.submenu, "section parent owns a submenu")
        XCTAssertEqual(containing?.submenu?.items.map(\.title), ["Finder", "Terminal"])

        let finder = containing?.submenu?.item(withTitle: "Finder")
        XCTAssertEqual(finder?.action,
                       #selector(HexpadAppDelegate.openContainingFolderInFinder(_:)))
        XCTAssertNil(finder?.target)
        let terminal = containing?.submenu?.item(withTitle: "Terminal")
        XCTAssertEqual(terminal?.action,
                       #selector(HexpadAppDelegate.openContainingFolderInTerminal(_:)))
        XCTAssertNil(terminal?.target)
    }

    // MARK: - Right-click behaviour

    func testRightClickSelectsClickedTabOnceAndConsultsProvider() {
        let store = TabStore()
        for text in ["a", "b", "c"] {
            store.addDocument(DocumentModel(text: text))
        }
        store.selectedIndex = 0
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.reloadTabs()

        var focuses = 0
        var changes = 0
        var consulted: [Int] = []
        bar.onFocus = { focuses += 1 }
        bar.onChange = { changes += 1 }
        let expectedMenu = NSMenu(title: "Tab")
        expectedMenu.addItem(NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: ""))
        bar.contextMenuProvider = { index in
            consulted.append(index)
            return expectedMenu
        }

        let buttons = tabButtons(in: bar)
        XCTAssertEqual(buttons.count, 3)
        rightClick(buttons[2])

        XCTAssertEqual(store.selectedIndex, 2, "the clicked tab is selected")
        XCTAssertEqual(consulted, [2], "the provider sees the clicked index once")
        XCTAssertEqual(focuses, 1)
        XCTAssertEqual(changes, 1, "the rightMouseUp must not fire a second selection")
        XCTAssertTrue(bar.lastContextMenu === expectedMenu, "the built menu is presented")
        XCTAssertEqual(bar.lastContextMenu?.items.map(\.title), ["Close Tab"])
    }

    func testRightClickFocusesClickedGroupBeforeBuildingMenu() throws {
        let (controller, _) = makeController()
        controller.addNewTab()
        controller.openSplitView()
        controller.moveToOtherView(nil) // puts a tab in group 2 and focuses it
        XCTAssertEqual(controller.focusedGroup, .secondary)
        controller.focusGroup(.primary)
        XCTAssertEqual(controller.focusedGroup, .primary)

        let secondaryBar = controller.allPanes[1].tabBar
        let buttons = tabButtons(in: secondaryBar)
        XCTAssertEqual(buttons.count, 1)
        rightClick(buttons[0])

        XCTAssertEqual(controller.focusedGroup, .secondary,
                       "the provider focuses this pane before building the menu")
        // The secondary bar had exactly one tab, so a non-nil menu proves the
        // provider for this pane (and not the primary one) was consulted.
        XCTAssertNotNil(secondaryBar.lastContextMenu)
        XCTAssertEqual(secondaryBar.lastContextMenu?.item(withTitle: "Move to Other View")?.action,
                       #selector(MainWindowController.moveToOtherView(_:)))
    }

    // MARK: - Validation

    func testControllerOwnedItemsValidateThroughTheResponderChain() {
        let (controller, _) = makeController()
        let menu = controller.buildTabContextMenu(for: 0)

        let reload = menu.item(withTitle: "Reload from Disk")!
        let print = menu.item(withTitle: "Print…")!
        let move = menu.item(withTitle: "Move to Other View")!
        let start = menu.item(withTitle: "Move Tab to Start")!
        let end = menu.item(withTitle: "Move Tab to End")!

        XCTAssertFalse(controller.validateMenuItem(reload), "untitled file has no source")
        XCTAssertTrue(controller.validateMenuItem(print), "a focused document can be printed")
        XCTAssertFalse(controller.validateMenuItem(move), "split is closed")
        XCTAssertFalse(controller.validateMenuItem(start), "one tab has nowhere to move")
        XCTAssertFalse(controller.validateMenuItem(end))

        controller.openSplitView()
        XCTAssertTrue(controller.validateMenuItem(move))
        controller.addNewTab()
        XCTAssertTrue(controller.validateMenuItem(start))
        XCTAssertTrue(controller.validateMenuItem(end))

        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(print), "no document to print")
    }

    func testCloseScopeItemsValidateThroughDelegate() throws {
        // The app-hosted delegate resolves `activeController` from the key
        // window (falling back to its own main controller), so drive its
        // validation against that controller and restore its tabs afterwards.
        let delegate = try XCTUnwrap(NSApp.delegate as? HexpadAppDelegate)
        let controller = try XCTUnwrap(
            NSApp.windows.compactMap { $0.contentViewController as? MainWindowController }.first
        )
        let menu = controller.buildTabContextMenu(for: 0, delegate: delegate)

        let butActive = menu.item(withTitle: "Close All but Active Document")!
        let toLeft = menu.item(withTitle: "Close All to the Left")!
        let toRight = menu.item(withTitle: "Close All to the Right")!
        let unchanged = menu.item(withTitle: "Close All Unchanged")!

        let store = controller.tabStore
        let originalDocuments = store.documents
        let originalIndex = store.selectedIndex
        defer {
            store.documents = originalDocuments
            store.selectedIndex = originalIndex
        }

        store.documents = [DocumentModel(text: "a")]
        store.selectedIndex = 0
        XCTAssertFalse(delegate.validateMenuItem(butActive), "one tab")
        XCTAssertFalse(delegate.validateMenuItem(toLeft), "one tab")
        XCTAssertFalse(delegate.validateMenuItem(toRight), "one tab")
        XCTAssertTrue(delegate.validateMenuItem(unchanged), "the only tab is clean")

        store.addDocument(DocumentModel(text: "b"))
        store.addDocument(DocumentModel(text: "c"))
        store.selectedIndex = 1
        XCTAssertTrue(delegate.validateMenuItem(butActive))
        // Existing validation is count-based: with three tabs every close
        // scope is applicable, whatever the selected tab's position.
        XCTAssertTrue(delegate.validateMenuItem(toLeft))
        XCTAssertTrue(delegate.validateMenuItem(toRight))
        XCTAssertTrue(delegate.validateMenuItem(unchanged))

        let finder = menu.item(withTitle: "Open Containing Folder")!.submenu!.item(withTitle: "Finder")!
        XCTAssertFalse(delegate.validateMenuItem(finder), "untitled buffer has no folder")
    }
}
