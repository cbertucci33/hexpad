import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19i: View > Synchronize Across Views. The zoom commands step every open
/// editor together while the toggle is on and only the focused editor while
/// off; the menu item carries the checkmark and validates against the split.
///
/// Mirrors the MacroUITests harness. UserDefaults is saved and restored around
/// every test because the stored `synchronizeZoom` is read at controller init.
final class ZoomSyncTests: XCTestCase {

    private var directory: URL!
    private var previousZoomSync: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-zoom-sync-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = directory
        previousZoomSync = UserDefaults.standard.object(forKey: "synchronizeZoom")
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        if let previousZoomSync {
            UserDefaults.standard.setValue(previousZoomSync, forKey: "synchronizeZoom")
        } else {
            UserDefaults.standard.removeObject(forKey: "synchronizeZoom")
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func zoomSyncMenuItem() throws -> NSMenuItem {
        let delegate = HexpadAppDelegate()
        let viewMenu = try XCTUnwrap(delegate.buildMainMenu().item(withTitle: "View")?.submenu)
        return try XCTUnwrap(viewMenu.item(withTitle: "Synchronize Across Views"))
    }

    // MARK: - Menu wiring and validation

    func testSynchronizeAcrossViewsItemLivesInTheZoomGroup() throws {
        let item = try zoomSyncMenuItem()
        XCTAssertNil(item.target, "validation reaches the controller through the responder chain")
        XCTAssertEqual(item.action, #selector(MainWindowController.toggleZoomSynchronize(_:)))
        XCTAssertEqual(item.keyEquivalent, "", "menu-only: no chord")

        let delegate = HexpadAppDelegate()
        let viewMenu = try XCTUnwrap(delegate.buildMainMenu().item(withTitle: "View")?.submenu)
        let titles = viewMenu.items.map(\.title)
        guard let index = titles.firstIndex(of: "Synchronize Across Views") else {
            XCTFail("the item exists")
            return
        }
        XCTAssertEqual(titles[index - 1], "Zoom Out")
        XCTAssertEqual(titles[index + 1], "Reset Zoom")
    }

    func testValidationAndCheckmarkFollowTheSplitAndToggle() throws {
        UserDefaults.standard.set(false, forKey: "synchronizeZoom")
        let (controller, _) = makeController()
        let item = try zoomSyncMenuItem()

        XCTAssertFalse(controller.synchronizeZoom)
        // Split closed: disabled, checkmark mirrors the stored state.
        XCTAssertFalse(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        // Split open: enabled, checkmark still mirrors the stored state.
        controller.openSplitView()
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        // Toggling flips the checkmark; the item stays enabled.
        controller.toggleZoomSynchronize(nil)
        XCTAssertTrue(controller.synchronizeZoom)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        // Closing the split disables it again.
        controller.closeSplitView()
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    // MARK: - Zoom behaviour

    func testZoomInWithSynchronizeOnAppliesToBothEditors() throws {
        UserDefaults.standard.set(true, forKey: "synchronizeZoom")
        let (controller, _) = makeController()
        XCTAssertTrue(controller.synchronizeZoom)
        controller.openSplitView()
        XCTAssertEqual(controller.allPanes.count, 2)
        let primary = controller.allPanes[0].editor
        let secondary = controller.allPanes[1].editor
        XCTAssertEqual(primary.zoomScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(secondary.zoomScale, 1.0, accuracy: 0.0001)

        controller.zoomIn()
        XCTAssertGreaterThan(primary.zoomScale, 1.0)
        XCTAssertEqual(primary.zoomScale, secondary.zoomScale, accuracy: 0.0001,
                       "both editors step in lockstep")
    }

    func testZoomInWithSynchronizeOffOnlyAffectsTheFocusedEditor() throws {
        UserDefaults.standard.set(false, forKey: "synchronizeZoom")
        let (controller, _) = makeController()
        XCTAssertFalse(controller.synchronizeZoom)
        controller.openSplitView()
        let primary = controller.allPanes[0].editor
        let secondary = controller.allPanes[1].editor

        controller.zoomIn()
        XCTAssertGreaterThan(primary.zoomScale, 1.0)
        XCTAssertEqual(secondary.zoomScale, 1.0, accuracy: 0.0001)
    }

    // MARK: - Uniform scale from divergent per-document zooms

    /// Per-document persistence can leave the panes at different scales before
    /// sync is switched on. Copying the focused editor's resulting scale (not
    /// stepping each pane by one point) must unify them.
    func testSynchronizeOnUnifiesPanesThatStartAtDifferentZooms() throws {
        UserDefaults.standard.set(true, forKey: "synchronizeZoom")
        let (controller, _) = makeController()
        XCTAssertTrue(controller.synchronizeZoom)
        controller.openSplitView()
        let primary = controller.allPanes[0].editor
        let secondary = controller.allPanes[1].editor
        secondary.setZoomScale(1.5)
        XCTAssertEqual(primary.zoomScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(secondary.zoomScale, 1.5, accuracy: 0.0001)

        controller.zoomIn()

        let focusedScale = primary.zoomScale
        XCTAssertGreaterThan(focusedScale, 1.0)
        XCTAssertEqual(secondary.zoomScale, focusedScale, accuracy: 0.0001,
                       "the focused pane's resulting scale is copied, not stepped")

        controller.zoomOut()

        XCTAssertEqual(secondary.zoomScale, primary.zoomScale, accuracy: 0.0001,
                       "zoom-out keeps the panes uniform too")
    }

    /// P-16: replaces the old reset test, which passed on delta-based code
    /// because resetting every pane also ended at 1.0. The new rule copies the
    /// focused pane's *absolute* scale, so panes at different base fonts must
    /// still end at the same multiplier — and that multiplier is the focused
    /// pane's result, not 1.0. Delta-based code steps each pane from its own
    /// base font and leaves the secondary at a different scale
    /// (0.8 - 1/20 here, instead of 1.4).
    func testSynchronizeOnCopiesFocusedScaleAcrossDifferentBaseFonts() throws {
        UserDefaults.standard.set(true, forKey: "synchronizeZoom")
        let (controller, _) = makeController()
        controller.openSplitView()
        let primary = controller.allPanes[0].editor
        let secondary = controller.allPanes[1].editor
        primary.setBodyFont(NSFont.monospacedSystemFont(ofSize: 10, weight: .regular))
        secondary.setBodyFont(NSFont.monospacedSystemFont(ofSize: 20, weight: .regular))
        primary.setZoomScale(1.5)
        secondary.setZoomScale(0.8)

        controller.zoomOut()

        let focusedScale = primary.zoomScale
        XCTAssertLessThan(focusedScale, 1.5)
        XCTAssertNotEqual(focusedScale, 1.0, accuracy: 0.0001,
                          "the focused pane did not reset, so the shared target is not 1.0")
        XCTAssertEqual(secondary.zoomScale, focusedScale, accuracy: 0.0001,
                       "the focused pane's absolute scale is copied, not stepped from the other base font")
        XCTAssertEqual(secondary.bodyFont.pointSize / secondary.zoomScale,
                       20, accuracy: 0.0001,
                       "the other pane's base font is preserved, not clobbered")
    }

    /// The command comes from the focused editor, so the secondary pane drives
    /// the shared target when it has focus.
    func testFocusedSecondaryPaneDrivesTheSharedScale() throws {
        UserDefaults.standard.set(true, forKey: "synchronizeZoom")
        let (controller, _) = makeController()
        controller.openSplitView()
        let primary = controller.allPanes[0].editor
        let secondary = controller.allPanes[1].editor
        // Focus first: focusing an as-yet-unbound empty pane rebinds it and
        // resets its zoom, so set the divergent scales afterwards.
        controller.focusGroup(.secondary)
        primary.setZoomScale(1.0)
        secondary.setZoomScale(1.5)

        controller.zoomIn()

        let focusedScale = secondary.zoomScale
        XCTAssertGreaterThan(focusedScale, 1.5)
        XCTAssertEqual(primary.zoomScale, focusedScale, accuracy: 0.0001,
                       "the focused secondary editor sets the target")
    }
}
