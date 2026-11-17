import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// AppKit-layer layout tests. The defect sweep that produced the find-bar bug
/// shipped because only HexpadKit logic had coverage: a zero-bounds frame
/// mistake in a view subclass was invisible to the suite. These instantiate the
/// real views and assert child frames land inside the bar at wide and narrow
/// widths.
final class LayoutTests: XCTestCase {

    func testFindBarChildrenStayInsideWideBounds() {
        let bar = FindBar()
        bar.frame = NSRect(x: 0, y: 0, width: 1400, height: bar.preferredHeight(for: 1400))
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
        bar.frame = NSRect(x: 0, y: 0, width: 1400, height: bar.preferredHeight(for: 1400))
        bar.layout()
        let close = bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == "×" }
        XCTAssertNotNil(close, "close button missing")
        guard let close else { return }
        XCTAssertGreaterThan(close.frame.minX, 1300, "close button must sit at the right edge, not at x=-28")
        XCTAssertLessThanOrEqual(close.frame.maxX, 1400)
    }

    /// Narrow windows wrap the options onto extra rows; nothing may overlap or
    /// escape. Grouping by row avoids comparing controls that deliberately sit
    /// on different lines.
    func testFindBarNarrowUsesExtraRowsWithoutOverlap() {
        let bar = FindBar()
        let height = bar.preferredHeight(for: 820)
        bar.frame = NSRect(x: 0, y: 0, width: 820, height: height)
        bar.layout()
        XCTAssertGreaterThan(height, 62, "narrow width needs more than the old two-row height")

        let frames = bar.subviews.map(\.frame).filter { $0.width > 0 }
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, bar.bounds.width)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, bar.bounds.height)
        }

        // Same-row children must not intersect (compare left to right).
        let rows = Dictionary(grouping: frames) { $0.minY }
        for row in rows.values {
            let sorted = row.sorted { $0.minX < $1.minX }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "controls on one row overlap")
            }
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

    // MARK: - Match case / extended mode wiring

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func button(_ title: String, in bar: FindBar) throws -> NSButton {
        try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    /// Clears the persisted preference around a test so a developer's real
    /// defaults can neither pre-enable match case nor be clobbered by the run.
    private func withCleanMatchCaseDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let key = FindBar.matchCaseDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try body()
    }

    func testMatchCaseCheckboxFiltersLiveSearch() throws {
        try withCleanMatchCaseDefaults {
            let (controller, _) = makeController()
            let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
            doc.text = "Alpha alpha ALPHA"

            controller.toggleFindBar()
            let bar = try XCTUnwrap(controller.findBar)
            bar.searchField.stringValue = "alpha"
            bar.performFind()
            XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3")

            let matchCase = try button("Match Case", in: bar)
            matchCase.performClick(nil)
            XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1",
                           "match case must reach SearchEngine through the find bar")

            matchCase.performClick(nil)
            XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3")
        }
    }

    func testMatchCasePreferenceIsPersisted() throws {
        try withCleanMatchCaseDefaults {
            let bar = FindBar()
            let matchCase = try button("Match Case", in: bar)
            XCTAssertEqual(matchCase.state, .off)

            matchCase.performClick(nil)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: FindBar.matchCaseDefaultsKey),
                          "toggling match case must persist like the search history")

            // A fresh bar (next launch) restores the choice.
            let reopened = FindBar()
            XCTAssertEqual(try button("Match Case", in: reopened).state, .on)
        }
    }

    func testExtendedModeTranslatesEscapesForLiteralSearch() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha\nbeta"

        controller.toggleFindBar()
        let bar = try XCTUnwrap(controller.findBar)
        bar.searchField.stringValue = "\\n"
        bar.performFind()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "No matches",
                       "literal mode must treat \\n as backslash + n")

        let extended = try button("Extended", in: bar)
        extended.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1",
                       "extended mode must translate \\n to the literal newline")

        let regex = try button("Regex", in: bar)
        regex.performClick(nil)
        XCTAssertEqual(extended.state, .off, "regex and extended are exclusive")
        XCTAssertEqual(regex.state, .on)

        extended.performClick(nil)
        XCTAssertEqual(regex.state, .off, "extended and regex are exclusive")
        XCTAssertEqual(extended.state, .on)
    }

    func testExtendedModeHonoursMatchCase() throws {
        try withCleanMatchCaseDefaults {
            let (controller, _) = makeController()
            let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
            doc.text = "Alpha\nALPHA\n"

            controller.toggleFindBar()
            let bar = try XCTUnwrap(controller.findBar)
            try button("Extended", in: bar).performClick(nil)
            bar.searchField.stringValue = "alpha\\n"
            bar.performFind()
            XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")

            try button("Match Case", in: bar).performClick(nil)
            XCTAssertEqual(bar.matchCountLabel.stringValue, "No matches",
                           "match case must apply to the extended-mode literal search")
        }
    }
}
