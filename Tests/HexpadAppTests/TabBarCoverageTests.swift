import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// AppKit-level coverage for tab-bar state that the mouse/tooltip/context-menu
/// test files do not assert: `reloadTabs()` bookkeeping, the drag-reorder state
/// machine, cross-group transfer and the per-pane callback contract. Setup
/// mirrors `TabBarMouseTests` / `CloseButtonPreferenceTests`: a real `TabStore`,
/// a framed `TabBarView`, then `reloadTabs()`.
final class TabBarCoverageTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                          styleMask: [.titled],
                          backing: .buffered,
                          defer: false)
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeBar(_ names: [String],
                         selectedIndex: Int = 0) -> (bar: TabBarView, store: TabStore, docs: [DocumentModel]) {
        let store = TabStore()
        let docs = names.map { name -> DocumentModel in
            let doc = DocumentModel(text: name)
            doc.name = name
            store.addDocument(doc)
            return doc
        }
        store.selectedIndex = selectedIndex
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: 32)
        bar.reloadTabs()
        return (bar, store, docs)
    }

    private func tabButtons(in bar: TabBarView) -> [TabButton] {
        bar.subviews.compactMap { $0 as? TabButton }
    }

    private func titleLabel(in button: TabButton) throws -> NSTextField {
        try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first,
                      "the tab's title label is missing")
    }

    /// The dirty dot is the only plain NSView subview (title is an NSTextField,
    /// × is an NSButton), so it can be located without exposing private API.
    private func dirtyIndicator(in button: TabButton) throws -> NSView {
        try XCTUnwrap(button.subviews.first {
            !($0 is NSTextField) && !($0 is NSButton)
        }, "the tab's dirty indicator is missing")
    }

    // MARK: - 5. reloadTabs() bookkeeping

    func testReloadTabsTracksStoreCountIndicesAndSelection() throws {
        let (bar, store, _) = makeBar(["a", "b", "c"], selectedIndex: 1)
        var buttons = tabButtons(in: bar)
        XCTAssertEqual(buttons.map(\.index), [0, 1, 2])
        XCTAssertEqual(buttons.map(\.frame.minX), [0, 142, 284])
        XCTAssertEqual(buttons.map(\.isSelected), [false, true, false])

        // A fourth document adds exactly one button; removing one drops it.
        store.addDocument(DocumentModel(text: "d"))
        bar.reloadTabs()
        buttons = tabButtons(in: bar)
        XCTAssertEqual(buttons.count, 4)
        XCTAssertEqual(buttons.last?.index, 3)

        store.removeDocument(at: 0)
        bar.reloadTabs()
        buttons = tabButtons(in: bar)
        XCTAssertEqual(buttons.count, 3)
        XCTAssertEqual(buttons.map(\.doc.text), ["b", "c", "d"])
    }

    func testSelectedIndexNotificationRefreshesButtonsWithoutReload() throws {
        let (bar, store, _) = makeBar(["a", "b", "c"], selectedIndex: 0)
        let buttons = tabButtons(in: bar)

        store.selectedIndex = 2
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"),
                                        object: nil)

        XCTAssertEqual(buttons.map(\.isSelected), [false, false, true])
        XCTAssertEqual(tabButtons(in: bar).map(\.isSelected), [false, false, true],
                       "selection follows the notification without rebuilding views")
    }

    func testDirtyIndicatorTracksUnsavedChangesPerDocument() throws {
        let (bar, _, docs) = makeBar(["clean", "dirty", "clean"])
        docs[1].setModified(true)
        bar.reloadTabs() // indicators are built from unsavedChanges
        let buttons = tabButtons(in: bar)
        XCTAssertTrue(try dirtyIndicator(in: buttons[0]).isHidden)
        XCTAssertFalse(try dirtyIndicator(in: buttons[1]).isHidden)
        XCTAssertTrue(try dirtyIndicator(in: buttons[2]).isHidden)

        // Live typing path: the document posts, the bar updates dots in place.
        docs[0].setModified(true)
        NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"),
                                        object: nil)
        XCTAssertFalse(try dirtyIndicator(in: buttons[0]).isHidden)

        bar.updateDirtyIndicators()
        XCTAssertFalse(try dirtyIndicator(in: buttons[0]).isHidden,
                       "an explicit refresh agrees with the notification path")

        docs[0].setModified(false)
        bar.updateDirtyIndicators()
        XCTAssertTrue(try dirtyIndicator(in: buttons[0]).isHidden,
                      "clearing the dirty bit hides the dot")
    }

    func testMaxTabLabelLengthTruncatesAndZeroMeansUnlimited() throws {
        let (bar, _, _) = makeBar(["report.txt"])
        let button = try XCTUnwrap(tabButtons(in: bar).first)

        XCTAssertEqual(try titleLabel(in: button).stringValue, "report.txt",
                       "0 is unlimited by default")

        bar.maxTabLabelLength = 5
        bar.reloadTabs()
        XCTAssertEqual(try titleLabel(in: try XCTUnwrap(tabButtons(in: bar).first)).stringValue,
                       "repo…", "the limit counts Characters and appends one ellipsis")

        bar.maxTabLabelLength = 1
        bar.reloadTabs()
        XCTAssertEqual(try titleLabel(in: try XCTUnwrap(tabButtons(in: bar).first)).stringValue, "…")

        bar.maxTabLabelLength = 10 // exact fit: no ellipsis
        bar.reloadTabs()
        XCTAssertEqual(try titleLabel(in: try XCTUnwrap(tabButtons(in: bar).first)).stringValue,
                       "report.txt")

        bar.maxTabLabelLength = 0 // back to unlimited
        bar.reloadTabs()
        XCTAssertEqual(try titleLabel(in: try XCTUnwrap(tabButtons(in: bar).first)).stringValue,
                       "report.txt")
    }

    // MARK: - 6. Drag-reorder state machine

    func testPreviewReSlotsButtonsButDoesNotMutateStoreUntilCommit() throws {
        let (bar, store, docs) = makeBar(["a", "b", "c"])
        var focusCount = 0
        var changeCount = 0
        bar.onFocus = { focusCount += 1 }
        bar.onChange = { changeCount += 1 }

        bar.beginDragPreview(from: 0)
        bar.previewDrag(to: 1)
        bar.previewDrag(to: 2)

        XCTAssertEqual(store.documents.map(\.text), ["a", "b", "c"],
                       "the preview never touches the store")
        XCTAssertTrue(store.documents[0] === docs[0])
        XCTAssertEqual(changeCount, 0, "no rebind per dragged slot")
        XCTAssertEqual(focusCount, 0, "a same-bar drag does not change the focused group")

        // Visual feedback is a frame change only; the buttons keep their
        // original indices until reloadTabs() runs on commit.
        let buttons = tabButtons(in: bar)
        XCTAssertEqual(buttons.map(\.index), [0, 1, 2])
        XCTAssertEqual(buttons[0].frame.minX, 284, "the dragged tab is previewed in slot 2")
        XCTAssertEqual(buttons[1].frame.minX, 0)
        XCTAssertEqual(buttons[2].frame.minX, 142)

        bar.commitDragPreview()
        XCTAssertEqual(store.documents.map(\.text), ["b", "c", "a"])
        XCTAssertEqual(tabButtons(in: bar).map(\.index), [0, 1, 2])
        XCTAssertEqual(tabButtons(in: bar)[2].frame.minX, 284)
    }

    func testReorderCommitKeepsTheSelectedDocumentSelected() throws {
        let (bar, store, docs) = makeBar(["a", "b", "c", "d"], selectedIndex: 2)
        XCTAssertTrue(store.selectedDocument === docs[2], "c starts selected")

        // Drag the selected tab toward the front. Reordering is window chrome:
        // it must follow the document, not leave the index pointing at a
        // different tab.
        bar.beginDragPreview(from: 2)
        bar.previewDrag(to: 0)
        bar.commitDragPreview()

        XCTAssertEqual(store.documents.map(\.text), ["c", "a", "b", "d"])
        XCTAssertTrue(store.selectedDocument === docs[2], "c is still the selected document")
        XCTAssertEqual(store.selectedIndex, 0)
        XCTAssertTrue(tabButtons(in: bar)[0].isSelected)
    }

    func testReorderCommitPostsExactlyOneNotificationAndChangeCallback() throws {
        let (bar, _, _) = makeBar(["a", "b", "c"])
        var notifications = 0
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TabStoreSelectedIndexDidChange"),
            object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        bar.onChange = { changes += 1 }

        bar.beginDragPreview(from: 0)
        bar.previewDrag(to: 2)
        XCTAssertEqual(notifications, 0)

        bar.commitDragPreview()
        XCTAssertEqual(notifications, 1, "one notification for the whole reorder")
        XCTAssertEqual(changes, 1, "one controller rebind for the whole reorder")
    }

    func testDragThatEndsWhereItStartedLeavesStoreAndCallbacksAlone() throws {
        let (bar, store, _) = makeBar(["a", "b", "c"])
        var changes = 0
        bar.onChange = { changes += 1 }

        bar.beginDragPreview(from: 1)
        bar.previewDrag(to: 2)
        bar.previewDrag(to: 1) // dragged back to its original slot
        bar.commitDragPreview()

        XCTAssertEqual(store.documents.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(changes, 0, "a no-op drag does not notify")
    }

    func testLockTabBarRefusesReorder() throws {
        let (bar, store, _) = makeBar(["a", "b", "c"])
        bar.lockTabBar = true
        var changes = 0
        bar.onChange = { changes += 1 }

        bar.beginDragPreview(from: 0)
        bar.previewDrag(to: 2)
        bar.commitDragPreview()

        XCTAssertEqual(store.documents.map(\.text), ["a", "b", "c"],
                       "a locked bar cannot start or commit a preview")
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(tabButtons(in: bar).map(\.frame.minX), [0, 142, 284])
    }

    /// P-05: `moveTab` is the single reorder entry point, so it owns the lock
    /// check. A direct call from a menu command must be a no-op while locked
    /// even though it never goes through the drag preview.
    func testLockedBarRefusesDirectMoveTab() throws {
        let (bar, store, docs) = makeBar(["a", "b", "c"])
        bar.lockTabBar = true
        var notifications = 0
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TabStoreSelectedIndexDidChange"),
            object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        bar.onChange = { changes += 1 }

        bar.moveTab(from: 0, to: 2)

        XCTAssertEqual(store.documents.map(\.text), ["a", "b", "c"],
                       "a locked bar refuses a direct reorder")
        XCTAssertEqual(store.selectedIndex, 0)
        XCTAssertTrue(store.selectedDocument === docs[0])
        XCTAssertEqual(notifications, 0, "a refused move posts no selection notice")
        XCTAssertEqual(changes, 0, "a refused move does not rebind the editor")
    }

    func testCrossGroupTransferMovesDocumentAndRefreshesBothBars() throws {
        let (sourceBar, sourceStore, docs) = makeBar(["a", "b", "c"], selectedIndex: 0)
        let (targetBar, targetStore, _) = makeBar(["x", "y"], selectedIndex: 0)
        sourceBar.siblingTabBar = targetBar
        targetBar.siblingTabBar = sourceBar

        var sourceChanges = 0
        var targetChanges = 0
        var targetFocuses = 0
        sourceBar.onChange = { sourceChanges += 1 }
        targetBar.onChange = { targetChanges += 1 }
        targetBar.onFocus = { targetFocuses += 1 }

        let moved = docs[2]
        sourceBar.transferTab(at: 2, doc: moved, to: targetBar, at: 1)

        XCTAssertEqual(sourceStore.documents.map(\.text), ["a", "b"])
        XCTAssertEqual(targetStore.documents.map(\.text), ["x", "c", "y"])
        XCTAssertTrue(targetStore.selectedDocument === moved, "the incoming tab is selected")
        XCTAssertEqual(tabButtons(in: sourceBar).count, 2)
        XCTAssertEqual(tabButtons(in: targetBar).count, 3)
        XCTAssertEqual(tabButtons(in: sourceBar).map(\.doc.text), ["a", "b"])
        XCTAssertEqual(tabButtons(in: targetBar).map(\.doc.text), ["x", "c", "y"])

        XCTAssertEqual(sourceChanges, 1, "the source pane rebinds once")
        XCTAssertEqual(targetChanges, 1, "the target pane rebinds once")
        XCTAssertEqual(targetFocuses, 1, "the drop focuses the target group")
    }

    // MARK: - 7. onChange / onFocus contract

    func testLeftClickSelectFiresFocusAndChangeExactlyOnce() throws {
        let (bar, store, _) = makeBar(["a", "b", "c"], selectedIndex: 0)
        var focuses = 0
        var changes = 0
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TabStoreSelectedIndexDidChange"),
            object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        bar.onFocus = { focuses += 1 }
        bar.onChange = { changes += 1 }

        let button = tabButtons(in: bar)[2]
        button.performClick(nil)

        XCTAssertEqual(store.selectedIndex, 2)
        XCTAssertEqual(focuses, 1, "one gesture focuses the group once")
        XCTAssertEqual(changes, 1, "one gesture rebinds once")
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(tabButtons(in: bar).map(\.isSelected), [false, false, true])
    }

    // MARK: - 8. Chrome colour refresh

    func testRefreshChromeColorsReResolvesBarAndButtonsAfterAppearanceChange() throws {
        let (bar, _, _) = makeBar(["a", "b"])
        window.contentView?.addSubview(bar)
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        let buttons = tabButtons(in: bar)

        func expected(_ color: NSColor, _ name: NSAppearance.Name) -> CGColor? {
            guard let appearance = NSAppearance(named: name) else { return nil }
            var resolved = color.cgColor
            appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
            return resolved
        }

        window.appearance = NSAppearance(named: .aqua)
        bar.refreshChromeColors()
        buttons.forEach { $0.refreshChromeColors() }
        let lightBar = bar.layer?.backgroundColor
        // buttons[0] is the selected tab (accent background); buttons[1] is the
        // unselected one that must track the plain control background.
        let unselected = buttons[1]
        let lightButton = unselected.layer?.backgroundColor
        XCTAssertEqual(lightBar, expected(.controlBackgroundColor, .aqua))
        XCTAssertEqual(lightButton, expected(.controlBackgroundColor, .aqua))

        window.appearance = NSAppearance(named: .darkAqua)
        // The bar propagates the appearance change to its buttons, so calling
        // only the bar's hook must re-resolve the whole strip.
        bar.viewDidChangeEffectiveAppearance()
        XCTAssertNotEqual(bar.layer?.backgroundColor, lightBar)
        XCTAssertEqual(bar.layer?.backgroundColor, expected(.controlBackgroundColor, .darkAqua))
        XCTAssertNotEqual(unselected.layer?.backgroundColor, lightButton)
        XCTAssertEqual(unselected.layer?.backgroundColor,
                       expected(.controlBackgroundColor, .darkAqua))

        // A selected tab resolves its own accent background, not the plain one.
        let selected = buttons[0]
        selected.isSelected = true
        selected.refreshChromeColors()
        XCTAssertEqual(selected.layer?.backgroundColor,
                       expected(.selectedContentBackgroundColor, .darkAqua))
    }
}
