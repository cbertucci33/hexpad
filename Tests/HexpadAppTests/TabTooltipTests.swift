import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19k-3: tab hover tooltip shows the full file path for a saved document and
/// the buffer name plus its creation moment for one that has never been saved.
/// Follows the `TabBarMouseTests` / `CloseButtonPreferenceTests` controller
/// setup: a `TabStore`, a `TabBarView` with a frame, then `reloadTabs()`.
final class TabTooltipTests: XCTestCase {

    /// A pinned instant far from the real clock, so a tooltip stamped with
    /// `Date()` (or any clock other than the injected one) cannot
    /// coincidentally render the same minute.
    private static let baseDate = Date(timeIntervalSince1970: 1_234_567_890)

    /// The bar's injected clock. Tests advance it to prove a stored creation
    /// moment survives reloads and pane moves instead of being re-stamped.
    private var now = TabTooltipTests.baseDate

    override func setUp() {
        super.setUp()
        now = Self.baseDate
        TabBarView.nowProvider = { [weak self] in self?.now ?? TabTooltipTests.baseDate }
    }

    override func tearDown() {
        TabBarView.nowProvider = Date.init
        super.tearDown()
    }

    private func makeBar(for documents: [DocumentModel]) -> (TabBarView, TabStore) {
        let store = TabStore()
        documents.forEach { store.addDocument($0) }
        store.selectedIndex = 0
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.reloadTabs()
        return (bar, store)
    }

    private func tabButtons(in bar: TabBarView) -> [TabButton] {
        bar.subviews.compactMap { $0 as? TabButton }
    }

    private func temporaryFile(named name: String = "notes.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-tooltip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try "saved text".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func tooltipDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter
    }

    /// The exact tooltip an unsaved buffer with `name` shows when its first
    /// sight was stamped at `date`. Built with the same formatter the button
    /// uses, but against the pinned clock rather than the wall clock.
    private func expectedTooltip(name: String = "Untitled", at date: Date) -> String {
        "\(name) — created \(tooltipDateFormatter().string(from: date))"
    }

    // MARK: - Saved document

    func testSavedDocumentTooltipIsFullPath() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let doc = DocumentModel(text: "saved text", filePath: file)
        let (bar, _) = makeBar(for: [doc])
        let button = try XCTUnwrap(tabButtons(in: bar).first)

        XCTAssertEqual(button.toolTip, file.path,
                       "a saved tab shows the exact on-disk path")
    }

    func testSavedThenModifiedDocumentKeepsPathTooltip() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let doc = DocumentModel(text: "saved text", filePath: file)
        let (bar, _) = makeBar(for: [doc])
        let button = try XCTUnwrap(tabButtons(in: bar).first)
        XCTAssertEqual(button.toolTip, file.path)

        doc.text = "saved text plus unsaved edits"
        NotificationCenter.default.post(
            name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)

        XCTAssertEqual(button.toolTip, file.path,
                       "the modified-did-change refresh must not clobber a saved path")
    }

    // MARK: - Unsaved document

    func testUnsavedDocumentTooltipHasNameAndCreationTime() throws {
        let doc = DocumentModel(text: "draft")   // filePath == nil, name == "Untitled"
        let (bar, _) = makeBar(for: [doc])

        let button = try XCTUnwrap(tabButtons(in: bar).first)
        let expected = expectedTooltip(at: now)
        XCTAssertEqual(button.toolTip, expected,
                       "the tooltip shows the pinned first-sight moment")

        // The creation moment is the document's first sight in the bar, so it
        // survives the bar's rebuilds even as the clock moves on: reloading
        // must not re-stamp the tab with the reload time.
        now = now.addingTimeInterval(3_600)
        bar.reloadTabs()
        bar.reloadTabs()
        bar.reloadTabs()
        XCTAssertEqual(tabButtons(in: bar).first?.toolTip, expected,
                       "reloading the bar must not change the tab's creation time")
    }

    func testNewDocumentInBarGetsItsOwnCreationTime() throws {
        let doc = DocumentModel(text: "first draft")
        let (bar, store) = makeBar(for: [doc])
        let firstExpected = expectedTooltip(at: now)
        XCTAssertEqual(tabButtons(in: bar).first?.toolTip, firstExpected)

        // A document opened later gets the moment it was first seen, and the
        // already-present tab keeps its earlier moment.
        now = now.addingTimeInterval(3_600)
        let newDoc = DocumentModel(text: "second draft")
        store.addDocument(newDoc)
        bar.reloadTabs()

        XCTAssertEqual(tabButtons(in: bar).first(where: { $0.doc === doc })?.toolTip,
                       firstExpected,
                       "the existing tab keeps its earlier creation time")
        let newExpected = expectedTooltip(at: now)
        XCTAssertEqual(tabButtons(in: bar).first(where: { $0.doc === newDoc })?.toolTip,
                       newExpected,
                       "the new tab is stamped with its own first-sight moment")

        // The new tab's time is stable across later rebuilds, too.
        now = now.addingTimeInterval(3_600)
        bar.reloadTabs()
        XCTAssertEqual(tabButtons(in: bar).first(where: { $0.doc === newDoc })?.toolTip,
                       newExpected,
                       "the new tab's creation time survives later rebuilds")
    }

    /// The creation-date map is shared between the split panes, so a tab moved
    /// to the other pane shows the moment it was first seen in the source.
    func testCrossPaneTransferKeepsCreationTime() throws {
        let doc = DocumentModel(text: "moving draft")
        let (sourceBar, sourceStore) = makeBar(for: [doc])
        let (targetBar, targetStore) = makeBar(for: [])
        sourceBar.siblingTabBar = targetBar
        targetBar.siblingTabBar = sourceBar

        let expected = expectedTooltip(at: now)
        XCTAssertEqual(tabButtons(in: sourceBar).first?.toolTip, expected)

        now = now.addingTimeInterval(3_600)
        sourceBar.transferTab(at: 0, doc: doc, to: targetBar, at: 0)
        XCTAssertTrue(sourceStore.documents.isEmpty)
        XCTAssertTrue(targetStore.documents.first === doc)
        XCTAssertEqual(tabButtons(in: targetBar).first?.toolTip, expected,
                       "the moved tab keeps the creation time it had in the source pane")

        // Round trip: moving back still reuses the shared first-sight moment.
        now = now.addingTimeInterval(3_600)
        targetBar.transferTab(at: 0, doc: doc, to: sourceBar, at: 0)
        XCTAssertEqual(tabButtons(in: sourceBar).first?.toolTip, expected,
                       "moving the tab back still keeps its original creation time")
    }

    func testRenamedUnsavedDocumentTooltipUsesItsName() throws {
        let doc = DocumentModel(text: "draft")
        doc.name = "Scratch"                      // renamed but still never saved
        let (bar, _) = makeBar(for: [doc])
        let button = try XCTUnwrap(tabButtons(in: bar).first)

        XCTAssertEqual(button.toolTip, expectedTooltip(name: "Scratch", at: now),
                       "a renamed untitled buffer shows its own name")
    }
}
