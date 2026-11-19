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
}
