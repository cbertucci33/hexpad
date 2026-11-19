import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19k-3: tab hover tooltip shows the full file path for a saved document and
/// the buffer name plus its creation moment for one that has never been saved.
/// Follows the `TabBarMouseTests` / `CloseButtonPreferenceTests` controller
/// setup: a `TabStore`, a `TabBarView` with a frame, then `reloadTabs()`.
final class TabTooltipTests: XCTestCase {

    private let unsavedPrefix = "Untitled — created "

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
        let tooltip = try XCTUnwrap(button.toolTip)
        XCTAssertTrue(tooltip.hasPrefix(unsavedPrefix),
                      "unsaved tooltip starts with the name and 'created': \(tooltip)")

        // The creation moment is the document's first sight in the bar, so it
        // survives the bar's rebuilds: reload a few times and the tooltip
        // must show the same time again.
        bar.reloadTabs()
        bar.reloadTabs()
        bar.reloadTabs()
        XCTAssertEqual(tooltip, tabButtons(in: bar).first?.toolTip,
                       "reloading the bar must not change the tab's creation time")
    }

    func testNewDocumentInBarGetsItsOwnCreationTime() throws {
        let doc = DocumentModel(text: "first draft")
        let (bar, store) = makeBar(for: [doc])
        let firstTooltip = try XCTUnwrap(tabButtons(in: bar).first?.toolTip)
        XCTAssertTrue(firstTooltip.hasPrefix(unsavedPrefix))

        // A newly opened document gets its own first-sight moment: the new
        // tab's time is not earlier than the old tab's.
        let newDoc = DocumentModel(text: "second draft")
        store.addDocument(newDoc)
        bar.reloadTabs()

        let newTooltip = try XCTUnwrap(
            tabButtons(in: bar).first(where: { $0.doc === newDoc })?.toolTip)
        XCTAssertTrue(newTooltip.hasPrefix(unsavedPrefix), newTooltip)
        XCTAssertGreaterThanOrEqual(tooltipTime(newTooltip),
                                    tooltipTime(firstTooltip),
                                    "the new document gets its own, not-earlier creation time")

        // The new tab's time is stable across later rebuilds, too.
        bar.reloadTabs()
        XCTAssertEqual(newTooltip,
                       tabButtons(in: bar).first(where: { $0.doc === newDoc })?.toolTip,
                       "the new tab's creation time survives later rebuilds")
    }

    /// Parses a tooltip's rendered creation time with the same format the
    /// button displays, so moments can be compared.
    private func tooltipTime(_ tooltip: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.date(from: String(tooltip.dropFirst(unsavedPrefix.count)))
            ?? Date.distantPast
    }

    func testRenamedUnsavedDocumentTooltipUsesItsName() throws {
        let doc = DocumentModel(text: "draft")
        doc.name = "Scratch"                      // renamed but still never saved
        let (bar, _) = makeBar(for: [doc])
        let button = try XCTUnwrap(tabButtons(in: bar).first)

        let tooltip = button.toolTip ?? ""
        XCTAssertTrue(tooltip.hasPrefix("Scratch — created "),
                      "a renamed untitled buffer shows its own name: \(tooltip)")
    }
}
