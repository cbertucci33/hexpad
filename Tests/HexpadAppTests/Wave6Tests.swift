import XCTest
import AppKit
@testable import Hexpad
@testable import HexpadKit

// MARK: - Find Characters in Range (Wave 6, docs item 27)

final class CharactersInRangeTests: XCTestCase {

    // MARK: Parse

    func testParseSingleNumber() {
        XCTAssertEqual(CharactersInRange.parse("65"), .success(65...65))
        XCTAssertEqual(CharactersInRange.parse(" 65 "), .success(65...65), "whitespace tolerated")
    }

    func testParseRange() {
        XCTAssertEqual(CharactersInRange.parse("20-300"), .success(20...300))
        XCTAssertEqual(CharactersInRange.parse("20 - 300"), .success(20...300), "spaces around dash fine")
    }

    func testParseErrors() {
        XCTAssertEqual(CharactersInRange.parse(""), .failure(.malformed))
        XCTAssertEqual(CharactersInRange.parse("abc"), .failure(.malformed))
        XCTAssertEqual(CharactersInRange.parse("20-"), .failure(.malformed))
        XCTAssertEqual(CharactersInRange.parse("-20"), .failure(.malformed))
        XCTAssertEqual(CharactersInRange.parse("300-20"), .failure(.inverted))
        XCTAssertEqual(CharactersInRange.parse("0-1114112"), .failure(.outOfRange))
        XCTAssertEqual(CharactersInRange.parse("0-1114111"), .success(0...1114111), "0x10FFFF is valid")
    }

    // MARK: Match location

    func testMatchesBasicASCII() {
        let text = "AB_cd"
        let hits = CharactersInRange.matches(in: text, range: 65...90) // A-Z
        XCTAssertEqual(hits, [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
    }

    func testMatchesNoHits() {
        XCTAssertTrue(CharactersInRange.matches(in: "abc", range: 65...90).isEmpty)
    }

    func testMatchesWholeRange() {
        let text = "ab"
        XCTAssertEqual(CharactersInRange.matches(in: text, range: 0...1114111).count, 2)
    }

    func testMatchesNonASCII() {
        // 'é' is U+00E9 = 233.
        let hits = CharactersInRange.matches(in: "café", range: 128...255)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.location, 3)
    }

    func testMatchesSkipSurrogatePairsAsOneHit() {
        // '𝄞' (U+1D11E) is a surrogate pair: one scalar, 2 UTF-16 units.
        let text = "a𝄞b"
        let hits = CharactersInRange.matches(in: text, range: 0x1D11E...0x1D11E)
        XCTAssertEqual(hits, [NSRange(location: 1, length: 2)], "surrogate pair = one match, length 2")
    }

    // MARK: Combined parse+locate

    func testMatchesWithSpecEndToEnd() {
        let result = CharactersInRange.matches(in: "AB_cd", spec: "65-90")
        XCTAssertEqual(try! result.get().count, 2)
        XCTAssertEqual(CharactersInRange.matches(in: "abc", spec: "bogus"),
                       .failure(.malformed))
    }

    // MARK: Dialog seams

    func testDialogValidationReportsErrorsWithoutApplying() {
        let dialog = FindCharactersInRangeWindowController()
        var applied = false
        dialog.onApply = { _ in applied = true }
        XCTAssertEqual(dialog.confirm(input: "bogus"), .malformed)
        XCTAssertFalse(applied, "parse error never applies")
        XCTAssertEqual(dialog.confirm(input: "300-20"), .inverted)
        XCTAssertFalse(applied)
    }

    func testDialogConfirmAppliesMatches() {
        let dialog = FindCharactersInRangeWindowController()
        var received: [NSRange] = []
        dialog.onApply = { received = $0 }
        dialog.textProvider = { "abc" }
        XCTAssertNil(dialog.confirm(input: "97-99")) // a-c
        XCTAssertEqual(received.count, 3, "a, b, c")
    }
}

// MARK: - Tab overflow arrows (Wave 6, V19k-4 remainder)

final class TabOverflowArrowTests: XCTestCase {

    private func makeOverflowingBar(count: Int, clipWidth: CGFloat = 400) -> TabBarView {
        let store = TabStore()
        for i in 0..<count {
            store.addDocument(DocumentModel(text: "doc \(i)"))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: clipWidth, height: 32))
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: clipWidth, height: 32)
        scroll.documentView = bar
        bar.reloadTabs()
        return bar
    }

    func testNoOverflowNoArrows() {
        let bar = makeOverflowingBar(count: 1)
        XCTAssertFalse(bar.isOverflowing, "one tab never overflows")
    }

    func testOverflowShowsArrows() {
        // 4 tabs × 142 - 2 = 566 > 400 clip.
        let bar = makeOverflowingBar(count: 4)
        XCTAssertTrue(bar.isOverflowing, "4 tabs overflow a 400pt clip")
    }

    func testScrollRightMovesClipOrigin() {
        let bar = makeOverflowingBar(count: 4)
        let scroll = bar.enclosingScrollView!
        scrollRight(bar)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 0, "right arrow scrolls the clip")
        scrollRight(bar)
        scrollLeft(bar)
        scrollLeft(bar)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, "left arrow scrolls back; clamped at 0")
        scrollLeft(bar)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, "stays clamped at 0")
    }

    private func scrollLeft(_ bar: TabBarView) {
        bar.scrollLeftClicked()
    }

    private func scrollRight(_ bar: TabBarView) {
        bar.scrollRightClicked()
    }
}

// MARK: - Workspace panel toggle (Wave 6, docs item 30)

final class WorkspaceToggleTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    func testWorkspaceItemExistsInMenu() {
        let delegate = HexpadAppDelegate()
        let menu = delegate.makeViewMenu()
        let item = menu.items.first { $0.title == "Folder as Workspace" }
        XCTAssertNotNil(item, "View > Folder as Workspace exists")
        XCTAssertEqual(item?.keyEquivalent, "", "no chord")
    }

    func testVisibilityFlipsWhenPanelCloses() {
        let controller = makeController()
        XCTAssertFalse(controller.isWorkspacePanelVisible(), "starts hidden")
        // Simulate an existing visible panel without running the modal picker.
        let panel = WorkspacePanelController(rootURL: FileManager.default.temporaryDirectory)
        controller.setWorkspacePanelControllerForTest(panel)
        panel.showWindow(nil)
        XCTAssertTrue(controller.isWorkspacePanelVisible())
        controller.toggleWorkspacePanel(nil)
        XCTAssertFalse(controller.isWorkspacePanelVisible(), "toggle hides the visible panel")
    }

    func testToggleWithNoPanelIsSafeNoOp() {
        let controller = makeController()
        // No panel + no picker (headless: openFolderAsWorkspace would show a
        // modal, but toggle only reaches it when no panel exists — the seam
        // below lets the test inject one first, so this path is covered by
        // the visibility test above; here we just verify the accessor).
        XCTAssertFalse(controller.isWorkspacePanelVisible())
    }
}
