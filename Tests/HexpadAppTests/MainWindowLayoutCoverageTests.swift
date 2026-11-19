import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// U4: AppKit-level coverage for MainWindowController's layout and focus.
///
/// Real view hierarchies (the TabContextMenuTests/LayoutTests setup pattern):
/// geometry tests drive the controller, resize the window and re-read frames
/// after `viewDidLayout()`; state tests assert the focus-model math —
/// focusGroup's swapped references, split open/close store moves and the
/// Post-It/Distraction-Free chrome-mode exclusions.
final class MainWindowLayoutCoverageTests: XCTestCase {

    // MARK: - Setup

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func statusBar(of controller: MainWindowController) throws -> StatusBar {
        try XCTUnwrap(controller.statusBar)
    }

    private func secondaryPane(of controller: MainWindowController) throws -> TabGroupPane {
        try XCTUnwrap(controller.allPanes.first { $0.group == .secondary })
    }

    /// Identity assertion for the focus-math references (TabStore/EditorContainer
    /// have no handy Equatable, so compare object identities via ObjectIdentifier).
    private func assertSameObject(_ a: AnyObject?, _ b: AnyObject?,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else {
            XCTFail("expected two non-nil objects", file: file, line: line)
            return
        }
        XCTAssertEqual(ObjectIdentifier(a), ObjectIdentifier(b),
                       "expected the same object", file: file, line: line)
    }

    /// Every corner of `frame` must land inside `bounds`.
    private func assertAllWithin(_ frame: NSRect, _ bounds: NSRect,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY, file: file, line: line)
    }

    // MARK: - Geometry: single-group layout

    func testSingleGroupLayoutGeometry() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 1200, height: 800))
        controller.viewDidLayout()

        let W = controller.view.bounds.width
        let H = controller.view.bounds.height
        let primary = controller.allPanes[0]
        let status = try statusBar(of: controller)

        // Status bar band at the top; tab bar reserves the bottom 32pt.
        XCTAssertFalse(primary.tabScrollView.isHidden)
        XCTAssertFalse(primary.tabBar.isHidden)
        XCTAssertEqual(primary.tabScrollView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(primary.tabScrollView.frame.width, W, accuracy: 0.5)
        XCTAssertEqual(primary.tabScrollView.frame.height, 32, accuracy: 0.5)
        XCTAssertEqual(primary.tabScrollView.frame.minY, H - 32, accuracy: 0.5)

        // Editor fills the middle band: below the status bar, above the tab bar.
        XCTAssertEqual(primary.editor.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.width, W, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.minY, 22, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.height, H - 54, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.maxY, primary.tabScrollView.frame.minY, accuracy: 0.5)

        XCTAssertEqual(status.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(status.frame.width, W, accuracy: 0.5)
        XCTAssertEqual(status.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(status.frame.height, 22, accuracy: 0.5)

        // Find bar hidden, no overlay reserved.
        XCTAssertNotNil(controller.findBar)
        XCTAssertTrue(controller.findBar?.isHidden == true)
        XCTAssertEqual(controller.findBar?.frame.width ?? 0, 0, accuracy: 0.5)
        XCTAssertEqual(controller.findBar?.frame.height ?? 0, 0, accuracy: 0.5)
    }

    // MARK: - Geometry: find bar overlay

    func testFindBarOverlayGeometryAtWideWidth() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 1500, height: 800))
        controller.viewDidLayout()
        controller.toggleFindBar()
        controller.viewDidLayout()

        let W = controller.view.bounds.width
        let H = controller.view.bounds.height
        let primary = controller.allPanes[0]
        let findBar = try XCTUnwrap(controller.findBar)

        XCTAssertGreaterThanOrEqual(W, 1340, "precondition: wide enough for the single-row bar")
        XCTAssertFalse(findBar.isHidden)
        XCTAssertEqual(findBar.preferredHeight(for: W), 36, accuracy: 0.5)
        XCTAssertEqual(findBar.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(findBar.frame.width, W, accuracy: 0.5)
        XCTAssertEqual(findBar.frame.height, 36, accuracy: 0.5)
        XCTAssertEqual(findBar.frame.minY, H - 32 - findBar.frame.height, accuracy: 0.5)
        // The editor fills the band up to the bar's top; nothing overlaps it.
        XCTAssertEqual(primary.editor.frame.maxY, findBar.frame.minY, accuracy: 0.5)
    }

    func testFindBarOverlayGeometryAtNarrowWidthUsesPreferredHeight() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 820, height: 700))
        controller.viewDidLayout()
        controller.toggleFindBar()
        controller.viewDidLayout()

        let W = controller.view.bounds.width
        let H = controller.view.bounds.height
        let primary = controller.allPanes[0]
        let findBar = try XCTUnwrap(controller.findBar)

        XCTAssertLessThan(W, 1340, "precondition: narrow window")
        XCTAssertFalse(findBar.isHidden)
        let findHeight = findBar.preferredHeight(for: W)
        XCTAssertGreaterThan(findHeight, 36, "narrow window: option rows wrap onto extra rows")
        XCTAssertEqual(findBar.frame.height, findHeight, accuracy: 0.5)
        XCTAssertEqual(findBar.frame.minY, H - 32 - findHeight, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.maxY, findBar.frame.minY, accuracy: 0.5)
    }

    // MARK: - Geometry: minimum-size floor

    func testMinimumWindowFloorKeepsStatusBarFieldsVisible() throws {
        let (controller, window) = makeController()
        // The 800pt width floor (MainWindow's minSize). AppKit reports the
        // titled window's effective minimum as slightly taller than the
        // 500pt content floor, so assert the floor's width and the height
        // floor's lower bound rather than the literal 500pt constant.
        XCTAssertEqual(window.minSize.width, 800, accuracy: 0.5,
                       "the 800pt width floor is pinned")
        XCTAssertGreaterThanOrEqual(window.minSize.height, 500,
                                    "the minimum-height floor is pinned")
        window.setContentSize(NSSize(width: 800, height: 500))
        controller.viewDidLayout()

        let status = try statusBar(of: controller)
        let W = controller.view.bounds.width
        XCTAssertEqual(status.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(status.frame.width, W, accuracy: 0.5)
        XCTAssertEqual(status.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(status.frame.height, 22, accuracy: 0.5)

        // Layout() positions the field labels against the bar's bounds; every
        // one must land inside it — the V19m "800pt keeps the fields visible"
        // invariant, the length + lines counters included.
        status.layout()
        XCTAssertFalse(status.subviews.isEmpty)
        for field in status.subviews {
            assertAllWithin(field.frame, status.bounds,
                            file: #filePath, line: #line)
        }
        XCTAssertTrue(status.subviews.contains { $0.frame.minX == 520 && $0.frame.width == 110 },
                      "the length counter is on screen at the 800pt floor")
        XCTAssertTrue(status.subviews.contains { $0.frame.minX == 638 && $0.frame.width == 80 },
                      "the lines counter is on screen at the 800pt floor")
    }

    // MARK: - Geometry: split view

    func testSplitOpenGeometry() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 1200, height: 800))
        controller.viewDidLayout()

        let W = controller.view.bounds.width
        let H = controller.view.bounds.height
        let status = try statusBar(of: controller)
        let primary = controller.allPanes[0]

        controller.openSplitView()
        controller.viewDidLayout()
        let secondary = try secondaryPane(of: controller)
        XCTAssertTrue(controller.isSplitViewOpen)

        // Two panes share the content width with a 1pt divider between them.
        let dividerWidth: CGFloat = 1
        let primaryWidth = floor((W - dividerWidth) / 2)
        XCTAssertEqual(primary.editor.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.width, primaryWidth, accuracy: 0.5)
        XCTAssertEqual(secondary.editor.frame.minX, primaryWidth + dividerWidth, accuracy: 0.5)
        XCTAssertEqual(secondary.editor.frame.width, W - primaryWidth - dividerWidth, accuracy: 0.5)

        // Both editors occupy the same band: below the status bar, above the tab bar.
        XCTAssertEqual(primary.editor.frame.minY, status.frame.height, accuracy: 0.5)
        XCTAssertEqual(secondary.editor.frame.minY, status.frame.height, accuracy: 0.5)
        XCTAssertEqual(secondary.editor.frame.maxY, H - 32, accuracy: 0.5)

        // The divider is the 1pt chrome between the panes, spanning the editor band.
        let divider = controller.view.subviews.first {
            $0.frame.minX == primaryWidth && $0.frame.width == 1
        }
        XCTAssertNotNil(divider, "the split opens with a 1pt divider")
        if let divider {
            XCTAssertEqual(divider.frame.minY, status.frame.height, accuracy: 0.5)
            XCTAssertEqual(divider.frame.height, secondary.editor.frame.height, accuracy: 0.5)
        }

        // Both tab bars reserve the bottom 32pt slot.
        XCTAssertEqual(primary.tabScrollView.frame.minY, H - 32, accuracy: 0.5)
        XCTAssertEqual(primary.tabScrollView.frame.height, 32, accuracy: 0.5)
        XCTAssertEqual(primary.tabScrollView.frame.width, primaryWidth, accuracy: 0.5)
        XCTAssertEqual(secondary.tabScrollView.frame.minY, H - 32, accuracy: 0.5)
        XCTAssertEqual(secondary.tabScrollView.frame.height, 32, accuracy: 0.5)
        XCTAssertEqual(secondary.tabScrollView.frame.width, W - primaryWidth - dividerWidth, accuracy: 0.5)
    }

    // MARK: - Focus model

    func testFocusGroupSwapsFocusMathReferencesConsistently() throws {
        let (controller, _) = makeController()
        let primary = controller.allPanes[0]
        let findBar = try XCTUnwrap(controller.findBar)

        // Before the split, every focus-following reference points at group 1.
        XCTAssertEqual(controller.focusedGroup, .primary)
        assertSameObject(controller.tabStore, primary.tabStore)
        assertSameObject(findBar.tabStoreRef, primary.tabStore)
        assertSameObject(findBar.editorRef, primary.editor)
        assertSameObject(controller.incrementalSearchBar?.editorRef, primary.editor)

        controller.openSplitView()
        XCTAssertTrue(controller.isSplitViewOpen)
        let secondary = try secondaryPane(of: controller)

        // Focusing the secondary group swaps the focus-following references.
        controller.focusGroup(.secondary)
        XCTAssertEqual(controller.focusedGroup, .secondary)
        assertSameObject(controller.tabStore, secondary.tabStore)
        assertSameObject(findBar.tabStoreRef, secondary.tabStore)
        assertSameObject(findBar.editorRef, secondary.editor)
        assertSameObject(controller.incrementalSearchBar?.editorRef, secondary.editor)
        // Status bar chrome is window-level and stays visible during focus moves.
        XCTAssertNotNil(controller.statusBar)

        // Focusing back swaps them all back.
        controller.focusGroup(.primary)
        XCTAssertEqual(controller.focusedGroup, .primary)
        assertSameObject(controller.tabStore, primary.tabStore)
        assertSameObject(findBar.editorRef, primary.editor)
        assertSameObject(controller.incrementalSearchBar?.editorRef, primary.editor)
    }

    func testClickingTabInUnfocusedGroupFocusesThatGroup() throws {
        let (controller, _) = makeController()
        controller.openSplitView()
        let secondary = try secondaryPane(of: controller)
        XCTAssertEqual(controller.focusedGroup, .primary)

        // The TabBarView seam a tab click funnels through (selectTab calls
        // onFocus?() first): clicking a tab in the unfocused group focuses it.
        secondary.tabBar.onFocus?()
        XCTAssertEqual(controller.focusedGroup, .secondary)
        assertSameObject(controller.tabStore, secondary.tabStore)
        assertSameObject(controller.findBar?.tabStoreRef, secondary.tabStore)
        assertSameObject(controller.findBar?.editorRef, secondary.editor)
    }

    func testAddNewTabLandsInFocusedGroup() throws {
        let (controller, _) = makeController()
        controller.openSplitView()
        let primary = controller.allPanes[0]
        let secondary = try secondaryPane(of: controller)
        XCTAssertEqual(primary.tabStore.count, 1)
        XCTAssertEqual(secondary.tabStore.count, 0)

        controller.focusGroup(.secondary)
        controller.addNewTab()
        XCTAssertEqual(secondary.tabStore.count, 1)
        XCTAssertEqual(primary.tabStore.count, 1, "the new tab must not leak into group 1")
        assertSameObject(controller.tabStore, secondary.tabStore)
        XCTAssertEqual(secondary.tabStore.selectedIndex, 0)
    }

    func testMoveToOtherViewFocusesReceivingGroup() throws {
        let (controller, _) = makeController()
        controller.openSplitView()
        XCTAssertTrue(controller.canMoveToOtherView())
        let primary = controller.allPanes[0]
        let secondary = try secondaryPane(of: controller)
        XCTAssertEqual(primary.tabStore.count, 1)

        controller.moveToOtherView(nil)
        XCTAssertEqual(controller.focusedGroup, .secondary)
        XCTAssertEqual(primary.tabStore.count, 0)
        XCTAssertEqual(secondary.tabStore.count, 1)
        assertSameObject(controller.tabStore, secondary.tabStore)
        XCTAssertNotNil(controller.tabStore.selectedDocument)
    }

    // MARK: - Split open/close state

    func testOpenSplitViewStartsGroup2Empty() throws {
        let (controller, _) = makeController()
        controller.openSplitView()
        XCTAssertTrue(controller.isSplitViewOpen)
        XCTAssertEqual(controller.allPanes.count, 2)
        let secondary = try secondaryPane(of: controller)
        XCTAssertTrue(secondary.tabStore.isEmpty)
        XCTAssertEqual(controller.allPanes[0].tabStore.count, 1,
                       "opening the split leaves group 1 untouched")
    }

    func testCloseSplitViewReturnsTabsToGroup1AndPreservesSelection() throws {
        let (controller, _) = makeController()
        // Build three tabs in group 1 and select the middle one.
        controller.addNewTab()
        controller.addNewTab()
        XCTAssertEqual(controller.allPanes[0].tabStore.count, 3)
        controller.tabStore.selectDocument(at: 1)
        let selectedBefore = try XCTUnwrap(controller.tabStore.selectedDocument)

        controller.openSplitView()
        controller.focusGroup(.secondary)
        controller.addNewTab() // a tab lands in group 2 before the close

        controller.closeSplitView()
        XCTAssertFalse(controller.isSplitViewOpen)
        XCTAssertEqual(controller.allPanes.count, 1)
        XCTAssertEqual(controller.focusedGroup, .primary)

        let primary = controller.allPanes[0]
        XCTAssertEqual(primary.tabStore.count, 4, "group 2's tabs come back to group 1")
        XCTAssertEqual(primary.tabStore.selectedIndex, 1,
                       "the primary selection is preserved (min(previous, count-1) clamp)")
        assertSameObject(primary.tabStore.documents[1], selectedBefore)
    }

    func testToggleSplitViewIsIdempotent() {
        let (controller, _) = makeController()
        XCTAssertFalse(controller.isSplitViewOpen)
        controller.toggleSplitView(nil)
        XCTAssertTrue(controller.isSplitViewOpen)
        controller.toggleSplitView(nil)
        XCTAssertFalse(controller.isSplitViewOpen)
        controller.toggleSplitView(nil)
        XCTAssertTrue(controller.isSplitViewOpen)
    }

    // MARK: - Window chrome (Post-It / Distraction Free)

    func testPostItHidesSlotsAndRestoresToolbarRoundTrip() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 1200, height: 800))
        controller.viewDidLayout()
        let primary = controller.allPanes[0]
        let status = try statusBar(of: controller)
        let originalToolbar = try XCTUnwrap(window.toolbar)

        controller.togglePostIt(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .postIt)
        XCTAssertNil(window.toolbar, "the toolbar is saved and removed while in Post-It")

        // Both chrome slots collapse to zero-height reservations.
        XCTAssertTrue(primary.tabScrollView.isHidden)
        XCTAssertEqual(primary.tabScrollView.frame, .zero)
        XCTAssertTrue(status.isHidden)
        XCTAssertEqual(status.frame, .zero)

        // The editor fills the whole view.
        let bounds = controller.view.bounds
        XCTAssertEqual(primary.editor.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.maxY, bounds.height, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.width, bounds.width, accuracy: 0.5)

        // Round trip: the same toolbar object comes back (the V19t interaction).
        controller.togglePostIt(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .normal)
        assertSameObject(window.toolbar, originalToolbar)
        XCTAssertFalse(primary.tabScrollView.isHidden)
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(status.frame.height, 22, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.minY, 22, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.maxY, controller.view.bounds.height - 32, accuracy: 0.5)
    }

    func testDistractionFreeGeometry() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 1200, height: 800))
        controller.viewDidLayout()
        let primary = controller.allPanes[0]
        let status = try statusBar(of: controller)

        controller.toggleDistractionFreeMode(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .distractionFree)

        let W = controller.view.bounds.width
        let H = controller.view.bounds.height
        let inset = floor(W * 0.15)

        // Editor-only: the chrome slots collapse to zero height.
        XCTAssertTrue(primary.tabScrollView.isHidden)
        XCTAssertEqual(primary.tabScrollView.frame, .zero)
        XCTAssertTrue(status.isHidden)
        XCTAssertEqual(status.frame, .zero)

        // The text column is inset ~15% on each side.
        XCTAssertEqual(primary.editor.frame.minX, inset, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.maxX, W - inset, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.width, W - inset * 2, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.maxY, H, accuracy: 0.5)

        // Leaving restores the normal layout.
        controller.toggleDistractionFreeMode(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .normal)
        XCTAssertFalse(primary.tabScrollView.isHidden)
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(primary.editor.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(primary.editor.frame.width, controller.view.bounds.width, accuracy: 0.5)
    }

    func testPostItAndDistractionFreeMutuallyExclude() throws {
        let (controller, window) = makeController()
        window.setContentSize(NSSize(width: 1200, height: 800))
        controller.viewDidLayout()
        let originalToolbar = try XCTUnwrap(window.toolbar)

        controller.togglePostIt(nil)
        XCTAssertEqual(controller.chromeMode, .postIt)
        XCTAssertNil(window.toolbar)

        // Entering Distraction Free first restores the outgoing Post-It chrome (V19e).
        controller.toggleDistractionFreeMode(nil)
        controller.viewDidLayout()
        XCTAssertEqual(controller.chromeMode, .distractionFree)
        assertSameObject(window.toolbar, originalToolbar)

        // Re-entering Post-It exits Distraction Free first.
        controller.togglePostIt(nil)
        XCTAssertEqual(controller.chromeMode, .postIt)
        XCTAssertNil(window.toolbar)

        // Leaving Post-It returns to normal chrome.
        controller.togglePostIt(nil)
        XCTAssertEqual(controller.chromeMode, .normal)
        assertSameObject(window.toolbar, originalToolbar)
    }
}
