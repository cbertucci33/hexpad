import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19k-1: mouse behaviour on the tab bar. A double-click on the empty strip
/// asks the controller for a new tab, while the same gesture on a tab belongs
/// to that button; a middle-click on a tab posts the ordinary close request.
final class TabBarMouseTests: XCTestCase {

    private func makeBar(tabCount: Int) -> TabBarView {
        let store = TabStore()
        for i in 0..<tabCount {
            store.addDocument(DocumentModel(text: "doc \(i)"))
        }
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.reloadTabs()
        return bar
    }

    private func tabButtons(in bar: TabBarView) -> [TabButton] {
        bar.subviews.compactMap { $0 as? TabButton }
    }

    private func mouseEvent(type: NSEvent.EventType,
                            location: NSPoint,
                            clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: location,
                           modifierFlags: [],
                           timestamp: 0,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: clickCount,
                           pressure: 0)!
    }

    // MARK: - Double-click on empty bar space

    func testDoubleClickOnEmptyBarRequestsNewTabExactlyOnce() {
        // One 140pt tab sits at x in [0,142); x=400 is empty bar space.
        let bar = makeBar(tabCount: 1)
        var requests = 0
        bar.onNewTabRequested = { requests += 1 }

        bar.mouseDown(with: mouseEvent(type: .leftMouseDown,
                                       location: NSPoint(x: 400, y: 16),
                                       clickCount: 2))

        XCTAssertEqual(requests, 1)
    }

    func testSingleClickOnEmptyBarDoesNotRequestNewTab() {
        let bar = makeBar(tabCount: 1)
        var requests = 0
        bar.onNewTabRequested = { requests += 1 }

        bar.mouseDown(with: mouseEvent(type: .leftMouseDown,
                                       location: NSPoint(x: 400, y: 16),
                                       clickCount: 1))

        XCTAssertEqual(requests, 0, "only a double-click creates a tab")
    }

    func testDoubleClickOnTabDoesNotRequestNewTab() {
        let bar = makeBar(tabCount: 2)
        var requests = 0
        bar.onNewTabRequested = { requests += 1 }
        let button = tabButtons(in: bar)[0]
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(button.frame.contains(point), "the point is on a tab, not empty space")

        // A click inside a tab belongs to TabButton (selection, drag,
        // double-click-to-close); the bar must leave it alone and consume it.
        bar.mouseDown(with: mouseEvent(type: .leftMouseDown,
                                       location: point,
                                       clickCount: 2))

        XCTAssertEqual(requests, 0, "a tab's double-click never requests a new tab")
    }

    // MARK: - Middle-click on a tab

    func testMiddleClickOnTabPostsCloseRequestWithItsIndex() {
        let bar = makeBar(tabCount: 3)
        let button = tabButtons(in: bar)[2]
        XCTAssertEqual(button.index, 2)

        var capturedBar: TabBarView?
        var capturedIndex: Int?
        var postCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TabCloseRequested"), object: nil, queue: nil
        ) { note in
            postCount += 1
            capturedBar = note.userInfo?["tabBar"] as? TabBarView
            capturedIndex = note.userInfo?["index"] as? Int
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        button.otherMouseDown(with: mouseEvent(type: .otherMouseDown,
                                               location: NSPoint(x: button.frame.midX,
                                                                 y: button.frame.midY),
                                               clickCount: 1))

        XCTAssertEqual(postCount, 1, "middle-click posts exactly one close request")
        XCTAssertEqual(capturedIndex, button.index, "the request targets the clicked tab")
        XCTAssertTrue(capturedBar === bar, "the request carries the owning bar")
    }
}
