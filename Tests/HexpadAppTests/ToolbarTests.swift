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
            (.toolbarReplace, "Replace", #selector(HexpadAppDelegate.toggleReplaceBar), true),
            (.toolbarZoomIn, "Zoom In", #selector(HexpadAppDelegate.zoomIn), true),
            (.toolbarZoomOut, "Zoom Out", #selector(HexpadAppDelegate.zoomOut), true),
            (.toolbarSyncVertical, "Synchronize Vertical Scrolling",
             #selector(MainWindowController.toggleSynchronizeScrolling(_:)), false),
            (.toolbarSyncHorizontal, "Synchronize Horizontal Scrolling",
             #selector(MainWindowController.toggleSynchronizeScrolling(_:)), false),
            (.toolbarWordWrap, "Word Wrap", #selector(HexpadAppDelegate.toggleWordWrap), true),
            (.toolbarShowAllCharacters, "Show All Characters",
             #selector(HexpadAppDelegate.toggleShowAllCharacters), false),
            // N++ extended View/tools group, appended after the View group.
            (.toolbarShowIndentGuide, "Show Indent Guide",
             #selector(HexpadAppDelegate.toggleShowIndentGuide), false),
            (.toolbarDocumentMap, "Document Map",
             #selector(HexpadAppDelegate.toggleDocumentMap), true),
            (.toolbarFunctionList, "Function List",
             #selector(MainWindowController.toggleFunctionList(_:)), false),
            (.toolbarFolderAsWorkspace, "Folder as Workspace",
             #selector(MainWindowController.toggleWorkspacePanel(_:)), false),
            (.toolbarMonitoring, "Monitoring (tail -f)",
             #selector(MainWindowController.toggleFileMonitoring(_:)), false),
            (.toolbarStartRecording, "Start Recording",
             #selector(MainWindowController.toggleMacroRecording(_:)), false),
            (.toolbarStopRecording, "Stop Recording",
             #selector(MainWindowController.stopRecordingMacro(_:)), false),
            (.toolbarPlayback, "Playback",
             #selector(MainWindowController.playLastMacro(_:)), false),
            (.toolbarRunMacroMultipleTimes, "Run a Macro Multiple Times…",
             #selector(MainWindowController.showRunMacroMultipleTimesDialog(_:)), false),
            (.toolbarSaveMacro, "Save Current Recorded Macro…",
             #selector(MainWindowController.saveRecordingAs(_:)), false)
        ]
    }
    
    private var expectedDefaultIdentifiers: [NSToolbarItem.Identifier] {
        [
            .toolbarNew, .toolbarOpen, .toolbarSave, .toolbarSaveAll,
            .toolbarClose, .toolbarCloseAll, .toolbarPrint,
            .space,
            .toolbarCut, .toolbarCopy, .toolbarPaste,
            .space,
            .toolbarUndo, .toolbarRedo,
            .space,
            .toolbarFind, .toolbarReplace,
            .space,
            .toolbarZoomIn, .toolbarZoomOut,
            .toolbarSyncVertical, .toolbarSyncHorizontal,
            .toolbarWordWrap, .toolbarShowAllCharacters,
            .toolbarShowIndentGuide, .toolbarDocumentMap,
            .toolbarFunctionList, .toolbarFolderAsWorkspace,
            .toolbarMonitoring,
            .toolbarStartRecording, .toolbarStopRecording,
            .toolbarPlayback, .toolbarRunMacroMultipleTimes, .toolbarSaveMacro
        ]
    }
    
    // MARK: - Ordering / customization
    
    func testDefaultItemsAreTheThirtyNPlusButtonsPlusFourSpacesInOrder() {
        let defaults = window.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(defaults, expectedDefaultIdentifiers)
        XCTAssertEqual(defaults.count, 34, "30 buttons + 4 group spaces")
        XCTAssertEqual(Set(expectedButtons.map(\.0)).count, 30, "30 distinct buttons")
    }
    
    func testAllowedItemsAreASupersetOfDefaultsAndIncludeFlexibleSpace() {
        let allowed = window.toolbarAllowedItemIdentifiers(toolbar)
        let defaults = window.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertTrue(Set(allowed).isSuperset(of: Set(defaults)))
        XCTAssertTrue(allowed.contains(.flexibleSpace))
    }
    
    func testDelegateReturnsAnItemForEveryAllowedButtonIdentifier() {
        for identifier in window.toolbarAllowedItemIdentifiers(toolbar) {
            // `.space`/`.flexibleSpace` are standard identifiers built by
            // AppKit; returning an item for them would create custom chrome.
            if identifier == .space || identifier == .flexibleSpace { continue }
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
    
    /// CB requirement: zero visible lines around toolbar icons. macOS 26 wraps
    /// every custom-view toolbar item in a glass capsule that reads as an
    /// outlined empty pill, even when the view itself is clear. Group spacing
    /// must therefore use AppKit's standard `.space` item (no view at all), and
    /// every button stays borderless.
    func testGroupSpacingAndButtonsDrawNoCustomChrome() {
        let defaults = window.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(defaults.filter { $0 == .space }.count, 4,
                       "four standard spaces separate the five N++ groups")

        for identifier in window.toolbarAllowedItemIdentifiers(toolbar) {
            if identifier == .space || identifier == .flexibleSpace { continue }
            let built = item(for: identifier)
            XCTAssertNil(built?.view,
                         "\(identifier.rawValue) must not use a custom view")
            if expectedButtons.contains(where: { $0.0 == identifier }) {
                XCTAssertFalse(built?.isBordered ?? true,
                               "\(identifier.rawValue) must render without a button border")
            }
        }
    }

    /// macOS 26 ignores `.none` on its own, so the titlebar must also be
    /// transparent or the 1pt hairline under the icons comes back.
    func testTitlebarDrawsNoSeparatorHairline() {
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.titlebarAppearsTransparent)
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
    
    // MARK: - Find vs Replace

    /// CB bug: both search icons toggled the same bar in the same mode. Find
    /// must open query-only; Replace must open with the replacement field.
    func testFindAndReplaceOpenDistinctFindBarModes() throws {
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        let bar = try XCTUnwrap(controller.findBar)

        controller.toggleFindBar()
        XCTAssertTrue(bar.isVisible)
        XCTAssertFalse(bar.isReplaceMode, "Find must open find-only mode")
        XCTAssertTrue(bar.replaceField.isHidden, "Find must hide the replace field")

        controller.toggleFindBar()
        XCTAssertFalse(bar.isVisible, "a second Find click closes find-only mode")

        controller.toggleReplaceBar()
        XCTAssertTrue(bar.isVisible)
        XCTAssertTrue(bar.isReplaceMode, "Replace must open replace mode")
        XCTAssertFalse(bar.replaceField.isHidden, "Replace must reveal the replace field")

        controller.toggleReplaceBar()
        XCTAssertFalse(bar.isVisible, "a second Replace click closes replace mode")
    }

    /// The two search buttons must not share a selector again.
    func testFindAndReplaceToolbarActionsAreDistinct() {
        let findAction = item(for: .toolbarFind)?.action
        let replaceAction = item(for: .toolbarReplace)?.action
        XCTAssertEqual(findAction, #selector(HexpadAppDelegate.toggleFindBar))
        XCTAssertEqual(replaceAction, #selector(HexpadAppDelegate.toggleReplaceBar))
        XCTAssertNotEqual(findAction, replaceAction)
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
