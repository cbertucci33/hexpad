import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19t: the N++ default toolbar. The expected tables below are written out
/// independently of the production table so a reordered or mis-wired button
/// fails the test rather than silently redefining "correct".
final class ToolbarTests: XCTestCase {
    
    private var window: MainWindow!
    private var appDelegate: HexpadAppDelegate!
    private var previousAppDelegate: NSApplicationDelegate?
    
    override func setUp() {
        super.setUp()
        // Delegate-targeted toolbar items resolve through NSApp.delegate, just
        // like their menu-section counterparts. NSApplication.delegate is weak,
        // so keep a strong reference here; restore whatever the host installed.
        previousAppDelegate = NSApp.delegate
        appDelegate = HexpadAppDelegate()
        NSApp.delegate = appDelegate
        window = MainWindow()
    }
    
    override func tearDown() {
        NSApp.delegate = previousAppDelegate
        appDelegate = nil
        window = nil
        super.tearDown()
    }
    
    private var toolbar: NSToolbar { window.toolbar! }
    
    private func item(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        window.toolbar(toolbar,
                       itemForItemIdentifier: identifier,
                       willBeInsertedIntoToolbar: false)
    }
    
    /// (identifier, label, action, targetsDelegate) in N++ default order.
    private var expectedButtons: [(NSToolbarItem.Identifier, String, Selector, Bool)] {
        [
            (.toolbarNew, "New", #selector(HexpadAppDelegate.newTab), true),
            (.toolbarOpen, "Open", #selector(HexpadAppDelegate.openFile), true),
            (.toolbarSave, "Save", #selector(HexpadAppDelegate.saveFile), true),
            (.toolbarSaveAll, "Save All", #selector(HexpadAppDelegate.saveAllFiles), true),
            (.toolbarClose, "Close", #selector(HexpadAppDelegate.closeTab), true),
            (.toolbarCloseAll, "Close All", #selector(HexpadAppDelegate.closeAllTabs), true),
            (.toolbarPrint, "Print", #selector(MainWindowController.printDocument(_:)), false),
            (.toolbarCut, "Cut", #selector(NSText.cut(_:)), false),
            (.toolbarCopy, "Copy", #selector(NSText.copy(_:)), false),
            (.toolbarPaste, "Paste", #selector(NSText.paste(_:)), false),
            (.toolbarUndo, "Undo", Selector(("undo:")), false),
            (.toolbarRedo, "Redo", Selector(("redo:")), false),
            (.toolbarFind, "Find", #selector(HexpadAppDelegate.toggleFindBar), true),
            (.toolbarReplace, "Replace", #selector(HexpadAppDelegate.toggleFindBar), true),
            (.toolbarZoomIn, "Zoom In", #selector(HexpadAppDelegate.zoomIn), true),
            (.toolbarZoomOut, "Zoom Out", #selector(HexpadAppDelegate.zoomOut), true),
            (.toolbarSyncVertical, "Synchronize Vertical Scrolling",
             #selector(MainWindowController.toggleSynchronizeScrolling(_:)), false),
            (.toolbarSyncHorizontal, "Synchronize Horizontal Scrolling",
             #selector(MainWindowController.toggleSynchronizeScrolling(_:)), false),
            (.toolbarWordWrap, "Word Wrap", #selector(HexpadAppDelegate.toggleWordWrap), true),
            (.toolbarShowAllCharacters, "Show All Characters",
             #selector(HexpadAppDelegate.toggleShowAllCharacters), false)
        ]
    }
    
    private var expectedSeparators: [NSToolbarItem.Identifier] {
        [.toolbarSeparatorAfterPrint, .toolbarSeparatorAfterPaste,
         .toolbarSeparatorAfterRedo, .toolbarSeparatorAfterReplace]
    }
    
    private var expectedDefaultIdentifiers: [NSToolbarItem.Identifier] {
        [
            .toolbarNew, .toolbarOpen, .toolbarSave, .toolbarSaveAll,
            .toolbarClose, .toolbarCloseAll, .toolbarPrint,
            .toolbarSeparatorAfterPrint,
            .toolbarCut, .toolbarCopy, .toolbarPaste,
            .toolbarSeparatorAfterPaste,
            .toolbarUndo, .toolbarRedo,
            .toolbarSeparatorAfterRedo,
            .toolbarFind, .toolbarReplace,
            .toolbarSeparatorAfterReplace,
            .toolbarZoomIn, .toolbarZoomOut,
            .toolbarSyncVertical, .toolbarSyncHorizontal,
            .toolbarWordWrap, .toolbarShowAllCharacters
        ]
    }
    
    // MARK: - Ordering / customization
    
    func testDefaultItemsAreTheTwentyNPlusButtonsPlusFourSeparatorsInOrder() {
        let defaults = window.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(defaults, expectedDefaultIdentifiers)
        XCTAssertEqual(defaults.count, 24, "20 buttons + 4 group separators")
        XCTAssertEqual(Set(expectedButtons.map(\.0)).count, 20, "20 distinct buttons")
    }
    
    func testAllowedItemsAreASupersetOfDefaultsAndIncludeFlexibleSpace() {
        let allowed = window.toolbarAllowedItemIdentifiers(toolbar)
        let defaults = window.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertTrue(Set(allowed).isSuperset(of: Set(defaults)))
        XCTAssertTrue(allowed.contains(NSToolbarItem.Identifier("flexibleSpace")))
    }
    
    func testDelegateReturnsAnItemForEveryAllowedIdentifier() {
        for identifier in window.toolbarAllowedItemIdentifiers(toolbar) {
            guard let built = item(for: identifier) else {
                XCTFail("no item for \(identifier.rawValue)")
                continue
            }
            XCTAssertEqual(built.itemIdentifier, identifier)
        }
    }
    
    // MARK: - Button presentation
    
    func testButtonsHaveExpectedLabelsToolTipsAndSFSymbolImages() {
        for (identifier, label, _, _) in expectedButtons {
            let built = item(for: identifier)
            XCTAssertEqual(built?.label, label, identifier.rawValue)
            XCTAssertFalse((built?.toolTip ?? "").isEmpty, "missing toolTip for \(identifier.rawValue)")
            XCTAssertNotNil(built?.image, "SF Symbol missing for \(identifier.rawValue)")
            XCTAssertFalse(built?.isNavigational ?? true, "buttons must be clickable")
        }
    }
    
    func testSeparatorItemsAreNavigationalRulesWithoutActions() {
        for identifier in expectedSeparators {
            let built = item(for: identifier)
            XCTAssertNotNil(built, identifier.rawValue)
            XCTAssertTrue(built?.isNavigational ?? false, identifier.rawValue)
            XCTAssertNil(built?.action, identifier.rawValue)
            XCTAssertTrue(built?.view is NSBox, identifier.rawValue)
        }
    }
    
    // MARK: - Action / target wiring (mirrors the menu sections)
    
    func testEachButtonActionAndTargetMatchesItsMenuConvention() {
        for (identifier, _, action, targetsDelegate) in expectedButtons {
            let built = try? XCTUnwrap(item(for: identifier))
            XCTAssertEqual(built?.action, action, "wrong action for \(identifier.rawValue)")
            if targetsDelegate {
                XCTAssertTrue(built?.target === appDelegate,
                              "\(identifier.rawValue) must target the app delegate")
            } else {
                XCTAssertNil(built?.target,
                             "\(identifier.rawValue) must resolve through the first responder chain")
            }
        }
    }
    
    /// The clipboard/undo buttons must use the exact selectors the Edit menu
    /// installs (including the raw ObjC undo:/redo: names).
    func testTextAndUndoButtonsReuseEditMenuSelectors() {
        let editMenu = appDelegate.buildMainMenu().item(withTitle: "Edit")?.submenu
        let menuSelectors = editMenu?.items.compactMap(\.action).map(\.description) ?? []
        for identifier in [NSToolbarItem.Identifier.toolbarCut,
                           .toolbarCopy, .toolbarPaste, .toolbarUndo, .toolbarRedo] {
            let action = item(for: identifier)?.action
            XCTAssertNotNil(action, identifier.rawValue)
            XCTAssertTrue(menuSelectors.contains(action?.description ?? ""),
                          "\(identifier.rawValue) action is not installed by the Edit menu")
        }
    }
    
    // MARK: - Native window tabbing

    /// Hexpad tabs documents in its own TabBarView. A MainWindow that kept the
    /// automatic default would let macOS merge Cmd+N windows into a native tab
    /// group and draw tab tiles in the titlebar leading edge.
    func testWindowDisallowsNativeWindowTabbing() {
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(MainWindow().tabbingMode, .disallowed,
                       "every MainWindow, not just the test fixture, opts out")
    }

    /// P-18: the app-wide opt-out is set in `applicationWillFinishLaunching`,
    /// before AppKit restores window state, not after launch. Calling the
    /// delegate's real lifecycle hook pins both the flag and the call site.
    func testWindowTabbingPolicyIsAppliedBeforeLaunchCompletes() {
        NSWindow.allowsAutomaticWindowTabbing = true
        appDelegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing,
                       "native tabbing must be off before restored windows can join a group")
    }

    // MARK: - Saved chrome restore
    
    /// The Post-It path captures `window.toolbar` and restores the same instance.
    /// A populated toolbar must survive that round trip unchanged.
    func testPostItChromeRestoreKeepsTheSameToolbarInstance() {
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        let original = window.toolbar
        XCTAssertNotNil(original)
        
        controller.togglePostIt(nil)
        XCTAssertNil(window.toolbar, "Post-It hides the toolbar")
        controller.togglePostIt(nil)
        XCTAssertTrue(window.toolbar === original, "restore must reinstall the original toolbar")
    }
}
