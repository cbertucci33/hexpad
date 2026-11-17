import XCTest
@testable import HexpadKit

/// Tab caption truncation, MRU ordering, and the Edit > Insert > Date Time
/// registry group.
final class TabPreferencesTests: XCTestCase {

    // MARK: - TabLabel

    func testTabLabelUnlimitedWhenMaxIsZeroOrNegative() {
        XCTAssertEqual(TabLabel.truncated("a very long document name.txt", maxLength: 0),
                       "a very long document name.txt")
        XCTAssertEqual(TabLabel.truncated("report.txt", maxLength: -3), "report.txt")
    }

    func testTabLabelTruncatesWithEllipsisAtTheLimit() {
        XCTAssertEqual(TabLabel.truncated("report.txt", maxLength: 5), "repo…")
        XCTAssertEqual(TabLabel.truncated("report.txt", maxLength: 9), "report.t…")
        XCTAssertEqual(TabLabel.truncated("abc", maxLength: 3), "abc",
                       "a name that fits is returned unchanged")
        XCTAssertEqual(TabLabel.truncated("abcdef", maxLength: 1), "…")
    }

    func testTabLabelCountsGraphemeClusters() {
        XCTAssertEqual(TabLabel.truncated("😀😀😀😀", maxLength: 3), "😀😀…")
    }

    // MARK: - MRUOrder

    func testMRUOrderStartsNewestFirstAndDeduplicates() {
        let order = MRUOrder(items: ["a", "b", "a", "c"])
        XCTAssertEqual(order.items, ["a", "b", "c"])
    }

    func testMRUTouchMovesAnElementToTheFront() {
        var order = MRUOrder(items: ["a", "b", "c"])
        order.touch("b")
        XCTAssertEqual(order.items, ["b", "a", "c"])
        order.touch("c")
        XCTAssertEqual(order.items, ["c", "b", "a"])
    }

    func testMRUSynchronizePrunesClosedAndAppendsNew() {
        var order = MRUOrder(items: ["a", "b", "c"])
        // b closed, d and e opened.
        order.synchronize(with: ["d", "a", "e", "c"])
        XCTAssertEqual(order.items, ["a", "c", "d", "e"],
                       "survivors keep usage order; new tabs append positionally")
    }

    func testMRUNextAndPreviousWalkTheOrderAndWrap() {
        let order = MRUOrder(items: ["a", "b", "c"])
        XCTAssertEqual(order.next(after: "a"), "b")
        XCTAssertEqual(order.next(after: "c"), "a")
        XCTAssertEqual(order.previous(after: "a"), "c")
        XCTAssertEqual(order.previous(after: "c"), "b")

        let single = MRUOrder(items: ["only"])
        XCTAssertNil(single.next(after: "only"))
        XCTAssertNil(single.previous(after: "only"))
        XCTAssertEqual(order.next(after: "missing"), "a",
                       "an unknown element falls back to the most recent")
    }

    // MARK: - Insert > Date Time registry group

    func testDateCommandsAreRegisteredInMenuOrder() {
        let registry = CommandRegistry.default
        XCTAssertEqual(registry.dateCommands.map(\.identifier), [
            "insert-datetime-short", "insert-datetime-long", "insert-datetime-custom"
        ])
        XCTAssertEqual(registry.dateCommands.map(\.title), [
            "Date Time (short)", "Date Time (long)", "Date Time (customized)"
        ])
        for command in registry.dateCommands {
            XCTAssertNotNil(registry.command(for: command.identifier))
        }
    }

    func testCustomDateCommandAcceptsThePatternParameter() {
        let date = Date(timeIntervalSince1970: 0)
        let registry = CommandRegistry(now: { date })
        let result = registry.execute("insert-datetime-custom",
                                      parameter: "'MARK'",
                                      text: "",
                                      selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result?.text, "MARK",
                       "the app passes the live Settings pattern through the parameter")
        XCTAssertEqual(result?.selection, NSRange(location: 4, length: 0))
    }
}
