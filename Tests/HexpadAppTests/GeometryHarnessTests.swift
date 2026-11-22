import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// U1 slice 1 (workboard card bdca238f): headless geometry invariants for the
/// status bar strip and the tab strip. Same fixture shape as `TabTooltipTests`:
/// a real `TabStore`, a framed `TabBarView`, then `reloadTabs()`. Frames are
/// asserted directly, no window or hosting required.
@MainActor
final class GeometryHarnessTests: XCTestCase {

    /// Tab strip geometry: one tab is 140pt wide with a 2pt gap between tabs.
    private let tabWidth: CGFloat = 140
    private let tabSpacing: CGFloat = 2

    // MARK: - Status bar

    func testStatusBarSubviewsStayInsideBar() {
        let statusBar = StatusBar(frame: NSRect(x: 0, y: 0, width: 1000, height: 22))

        for subview in statusBar.subviews {
            XCTAssertTrue(subview.frame.minX >= 0,
                          "status bar subview \(subview) has minX \(subview.frame.minX) < 0")
            XCTAssertTrue(subview.frame.minY >= 0,
                          "status bar subview \(subview) has minY \(subview.frame.minY) < 0")
            XCTAssertTrue(subview.frame.maxX <= statusBar.bounds.width,
                          "status bar subview \(subview) has maxX \(subview.frame.maxX) > width \(statusBar.bounds.width)")
            XCTAssertTrue(subview.frame.maxY <= statusBar.bounds.height,
                          "status bar subview \(subview) has maxY \(subview.frame.maxY) > height \(statusBar.bounds.height)")
        }
    }

    // MARK: - Tab bar

    private func makeBar(for documents: [DocumentModel]) -> (bar: TabBarView, store: TabStore) {
        let store = TabStore()
        documents.forEach { store.addDocument($0) }
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.reloadTabs()
        return (bar, store)
    }

    private func tabButtons(in bar: TabBarView) -> [TabButton] {
        bar.subviews.compactMap { $0 as? TabButton }
    }

    func testTabButtonsStayInsideClipAfterReload() {
        let documents = ["a", "b", "c"].map { DocumentModel(text: $0) }
        let (bar, _) = makeBar(for: documents)
        let buttons = tabButtons(in: bar)

        XCTAssertEqual(buttons.count, 3, "reloadTabs() must build one button per stored document")

        for button in buttons {
            XCTAssertTrue(button.frame.minX >= 0, "tab button \(button) has minX \(button.frame.minX) < 0")
            XCTAssertTrue(button.frame.minY >= 0, "tab button \(button) has minY \(button.frame.minY) < 0")
            XCTAssertTrue(button.frame.maxX <= bar.bounds.width, "tab button \(button) has maxX \(button.frame.maxX) > width \(bar.bounds.width)")
            XCTAssertTrue(button.frame.maxY <= bar.bounds.height, "tab button \(button) has maxY \(button.frame.maxY) > height \(bar.bounds.height)")
        }

        let sorted = buttons.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(sorted.count, 3)
        for i in 1..<sorted.count {
            let previous = sorted[i - 1]
            let next = sorted[i]
            XCTAssertTrue(next.frame.minX >= previous.frame.maxX + tabSpacing,
                          "adjacent tab buttons overlap: previous ends at \(previous.frame.maxX), next starts at \(next.frame.minX), expected >= \(previous.frame.maxX + tabSpacing)")
        }
    }

    func testTabBarButtonsMatchStoreCount() {
        let documents = ["a", "b", "c"].map { DocumentModel(text: $0) }
        let (bar, store) = makeBar(for: documents)

        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(tabButtons(in: bar).count, 3, "the bar must render one button per stored document after reloadTabs()")
    }
}
