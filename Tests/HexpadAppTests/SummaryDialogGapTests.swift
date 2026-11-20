import XCTest
import AppKit
@testable import Hexpad
@testable import HexpadKit

// MARK: - Summary dialog gaps (Wave 5B): timestamps + chars-excluding-EOLs

final class SummaryDialogGapTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return controller
    }

    // MARK: Chars excluding EOLs

    func testCharacterCountExcludesEOLs() {
        // "ab\ncd\n" = 4 chars excluding both LFs; 6 with.
        XCTAssertEqual(SummaryWindowController.characterCount(excludingEOLs: "ab\ncd\n"), 4)
        XCTAssertEqual(SummaryWindowController.characterCount(excludingEOLs: "ab\r\ncd\r\n"), 4, "CRLF counts as one EOL per break")
        XCTAssertEqual(SummaryWindowController.characterCount(excludingEOLs: "a\r\nb\nc\rd"), 4, "mixed endings")
        XCTAssertEqual(SummaryWindowController.characterCount(excludingEOLs: ""), 0)
        XCTAssertEqual(SummaryWindowController.characterCount(excludingEOLs: "\n\n\n"), 0, "all-EOL text")
        XCTAssertEqual(SummaryWindowController.characterCount(excludingEOLs: "abc"), 3, "no EOLs")
    }

    func testSummaryReportShowsBothCharacterRows() throws {
        let controller = makeController()
        let doc = DocumentModel(text: "ab\ncd\n")
        controller.tabStore.documents = [doc]
        let report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Characters: 4"), "excluding EOLs by default\n\(report)")
        XCTAssertTrue(report.contains("Characters (with EOLs): 6"), "second row keeps the raw count\n\(report)")
    }

    // MARK: File timestamps

    func testTimestampsPresentForFileBackedDoc() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stamped.txt")
        try "stamped\n".write(to: url, atomically: true, encoding: .utf8)

        let stamps = SummaryWindowController.fileTimestamps(for: url)
        let created = try XCTUnwrap(stamps.created)
        let modified = try XCTUnwrap(stamps.modified)
        let accessed = try XCTUnwrap(stamps.accessed)
        // All three should be near now (within a minute).
        let now = Date()
        XCTAssertLessThan(abs(created.timeIntervalSince(now)), 60)
        XCTAssertLessThan(abs(modified.timeIntervalSince(now)), 60)
        XCTAssertLessThan(abs(accessed.timeIntervalSince(now)), 60)
    }

    func testTimestampsNilForUntitled() {
        let stamps = SummaryWindowController.fileTimestamps(for: nil)
        XCTAssertNil(stamps.created)
        XCTAssertNil(stamps.modified)
        XCTAssertNil(stamps.accessed)
    }

    func testReportShowsDashTimestampsForUntitled() {
        let controller = makeController()
        controller.tabStore.documents = [DocumentModel(text: "scratch")]
        let report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Created: -"), "untitled shows dashes\n\(report)")
        XCTAssertTrue(report.contains("Modified: -"), "\n\(report)")
        XCTAssertTrue(report.contains("Accessed: -"), "\n\(report)")
    }

    // MARK: Change History wiring (controller side)

    func testSavePathRecordsHistory() throws {
        let controller = makeController()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hist.txt")
        try "v1\n".write(to: url, atomically: true, encoding: .utf8)

        let doc = DocumentModel(text: "v1\n", filePath: url)
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
        doc.text = "v2\n"
        controller.saveFile()

        let entries = controller.history(for: doc).menuEntries
        XCTAssertTrue(entries.contains { $0.title.hasPrefix("Saved on") },
                      "saving records a save point\n\(entries)")
    }

    func testRevertRestoresSnapshotAndClearsDirty() throws {
        let controller = makeController()
        let doc = DocumentModel(text: "original")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0

        // Simulate a save point, then edit.
        controller.recordSavePoint(for: doc)
        doc.text = "heavily edited"
        doc.setModified(true)
        XCTAssertTrue(doc.unsavedChanges)

        let history = controller.history(for: doc)
        let saved = try XCTUnwrap(history.menuEntries.first { $0.title.hasPrefix("Saved on") })
        let item = NSMenuItem(title: saved.title,
                              action: #selector(MainWindowController.revertToHistoryEntry(_:)),
                              keyEquivalent: "")
        item.representedObject = saved
        controller.revertToHistoryEntry(item)

        XCTAssertEqual(doc.text, "original", "revert restores the exact snapshot")
        XCTAssertFalse(doc.unsavedChanges, "revert clears dirty")
    }

    func testRevertDisabledForReadOnlyDocs() {
        let controller = makeController()
        let doc = DocumentModel(text: "locked")
        doc.setReadOnly(true)
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
        controller.recordSavePoint(for: doc)

        let history = controller.history(for: doc)
        guard let saved = history.menuEntries.first(where: { $0.title.hasPrefix("Saved on") }) else {
            return XCTFail("save point missing")
        }
        let item = NSMenuItem(title: saved.title,
                              action: #selector(MainWindowController.revertToHistoryEntry(_:)),
                              keyEquivalent: "")
        item.representedObject = saved
        XCTAssertFalse(controller.validateMenuItem(item), "read-only docs refuse revert")
    }

    func testEmptyHistoryShowsNoHistoryRow() {
        let controller = makeController()
        let doc = DocumentModel(text: "fresh")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
        let menu = NSMenu()
        HexpadAppDelegate.populateChangeHistoryMenu(menu, controller: controller)
        XCTAssertTrue(menu.items.contains { $0.title == "No History" && !$0.isEnabled },
                      "empty history shows a disabled row\n\(menu.items.map({ $0.title }))")
    }
}
