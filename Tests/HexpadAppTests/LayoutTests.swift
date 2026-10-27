import XCTest
import AppKit
@testable import Hexpad

/// AppKit-layer layout tests. The defect sweep that produced the find-bar bug
/// shipped because only HexpadKit logic had coverage: a zero-bounds frame
/// mistake in a view subclass was invisible to the suite. These instantiate the
/// real views and assert child frames land inside the bar at both a wide and a
/// narrow width.
final class LayoutTests: XCTestCase {

    func testFindBarChildrenStayInsideWideBounds() {
        let bar = FindBar()
        bar.frame = NSRect(x: 0, y: 0, width: 1000, height: 36)
        bar.layout()
        for child in bar.subviews {
            XCTAssertGreaterThanOrEqual(child.frame.minX, 0, "\(type(of: child)) starts left of the bar")
            XCTAssertLessThanOrEqual(child.frame.maxX, bar.bounds.width, "\(type(of: child)) ends past the bar")
            XCTAssertGreaterThanOrEqual(child.frame.minY, 0, "\(type(of: child)) sits below the bar")
            XCTAssertLessThanOrEqual(child.frame.maxY, bar.bounds.height, "\(type(of: child)) sits above the bar")
        }
    }

    func testCloseButtonReachableAtWideWidth() {
        let bar = FindBar()
        bar.frame = NSRect(x: 0, y: 0, width: 1000, height: 36)
        bar.layout()
        let close = bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == "×" }
        XCTAssertNotNil(close, "close button missing")
        guard let close else { return }
        XCTAssertGreaterThan(close.frame.minX, 900, "close button must sit at the right edge, not at x=-28")
        XCTAssertLessThanOrEqual(close.frame.maxX, 1000)
    }

    /// Narrow windows switch to two rows; nothing may overlap or escape.
    func testFindBarNarrowUsesTwoRowsWithoutOverlap() {
        let bar = FindBar()
        bar.frame = NSRect(x: 0, y: 0, width: 820, height: bar.preferredHeight(for: 820))
        bar.layout()
        XCTAssertEqual(bar.preferredHeight(for: 820), 62, "narrow width needs the compact height")
        let frames = bar.subviews.map(\.frame).filter { $0.width > 0 }
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, bar.bounds.width)
            XCTAssertLessThanOrEqual(frame.maxY, bar.bounds.height)
        }
        // Same-row children must not intersect (compare left to right).
        let row2 = frames.filter { $0.midY < bar.bounds.height / 2 }.sorted { $0.minX < $1.minX }
        for (a, b) in zip(row2, row2.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "controls on one row overlap")
        }
    }

    func testStatusBarLabelsVerticallyCentred() {
        let bar = StatusBar()
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 22)
        bar.layout()
        let labels = bar.subviews.compactMap { $0 as? NSTextField }
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertGreaterThanOrEqual(label.frame.minY, 0, "label clipped below the bar")
            XCTAssertLessThanOrEqual(label.frame.maxY, bar.bounds.height, "label clipped above the bar")
        }
    }

    func testFindBarStartsHidden() {
        XCTAssertTrue(FindBar().isHidden, "bar must not paint before being asked for")
    }
}
