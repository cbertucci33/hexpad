import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

final class TestWindowShouldCloseTests: XCTestCase {

    private func makeDelegateWithExtraWindow() -> (HexpadAppDelegate, MainWindowController, NSWindow) {
        let delegate = HexpadAppDelegate()
        delegate.newWindow()
        let controller = delegate.additionalWindowControllersForTest.first!
        let window = controller.mainWindow!
        return (delegate, controller, window)
    }

    override func tearDown() {
        // best-effort cleanup handled by individual tests
        super.tearDown()
    }

    // MARK: - Decision core (dialog-free)

    func testWindowShouldCloseResolutionNoDirtyProceeds() {
        XCTAssertTrue(HexpadAppDelegate.windowShouldCloseResolution(dirtyCount: 0,
                                                                   response: .alertThirdButtonReturn))
        XCTAssertTrue(HexpadAppDelegate.windowCloseResolution(dirtyCount: 0,
                                                             response: .alertThirdButtonReturn))
        XCTAssertTrue(HexpadAppDelegate.closeWindowResolution(dirtyCount: 0,
                                                             response: .alertThirdButtonReturn))
        XCTAssertTrue(HexpadAppDelegate.shouldCloseWindowResolution(dirtyCount: 0,
                                                                   response: .alertThirdButtonReturn))
    }

    func testWindowShouldCloseResolutionSaveProceeds() {
        XCTAssertTrue(HexpadAppDelegate.windowShouldCloseResolution(dirtyCount: 2,
                                                                   response: .alertFirstButtonReturn))
    }

    func testWindowShouldCloseResolutionSaveFailureAborts() {
        XCTAssertFalse(HexpadAppDelegate.windowShouldCloseResolution(dirtyCount: 2,
                                                                    response: .alertFirstButtonReturn,
                                                                    saveSucceeded: false))
    }

    func testWindowShouldCloseResolutionDontSaveProceeds() {
        XCTAssertTrue(HexpadAppDelegate.windowShouldCloseResolution(dirtyCount: 2,
                                                                   response: .alertSecondButtonReturn))
    }

    func testWindowShouldCloseResolutionCancelAborts() {
        XCTAssertFalse(HexpadAppDelegate.windowShouldCloseResolution(dirtyCount: 2,
                                                                    response: .alertThirdButtonReturn))
    }

    // MARK: - windowShouldClose itself (clean window)

    func testWindowShouldCloseCleanExtraWindowReturnsTrue() {
        let (delegate, _, window) = makeDelegateWithExtraWindow()
        defer { delegate.closeAllAdditionalWindowsForTest() }
        XCTAssertTrue(delegate.windowShouldClose(window))
    }
}