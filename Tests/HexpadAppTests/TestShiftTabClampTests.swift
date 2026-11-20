import XCTest
import AppKit
@testable import Hexpad

/// Unit coverage for the Shift+Tab backtab probe range clamp. The regression:
/// `NSMakeRange(max(0, location - 4), 4)` ran past the end of documents shorter
/// than four characters, so `NSString.substring(with:)` raised NSRangeException.
/// These exercise the pure clamp helper directly - no window, no runModal.
final class TestShiftTabClampTests: XCTestCase {

    func testShortDocumentClampsRangeToBufferLength() {
        // A two-character buffer with the caret at its end: the old 4-wide
        // range (0, 4) was out of bounds. The clamp keeps it within (0, 2).
        let range = MainWindowController.backtabCheckRange(location: 2,
                                                            textLength: 2,
                                                            width: 4)
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 2)
        XCTAssertLessThanOrEqual(NSMaxRange(range), 2)
    }

    func testEmptyDocumentReturnsZeroLengthRange() {
        let range = MainWindowController.backtabCheckRange(location: 0,
                                                            textLength: 0,
                                                            width: 4)
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 0)
    }

    func testLongDocumentKeepsFullWidthRange() {
        // Documents longer than the indent width keep the original behaviour:
        // caret at 10 in a 10-character buffer probes (6, 4), as before.
        let range = MainWindowController.backtabCheckRange(location: 10,
                                                            textLength: 10,
                                                            width: 4)
        XCTAssertEqual(range.location, 6)
        XCTAssertEqual(range.length, 4)
    }

    func testCaretNearStartClampsToZeroButKeepsWidth() {
        let range = MainWindowController.backtabCheckRange(location: 1,
                                                            textLength: 20,
                                                            width: 4)
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 4)
    }

    func testTabWidthProbeRespectsIndentWidth() {
        // A one-character tab unit never runs past a short buffer either.
        let range = MainWindowController.backtabCheckRange(location: 1,
                                                            textLength: 1,
                                                            width: 1)
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 1)
    }
}
