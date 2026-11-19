import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// View > Summary… (V19h): the document-stats dialog's report generator.
/// Mirrors the MacroUITests harness (real controller + editor over the
/// fixture document); the report itself is the pure seam the panel displays.
final class SummaryDialogTests: XCTestCase {

    private var window: MainWindow!
    private var controller: MainWindowController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        window = MainWindow()
        controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
    }

    override func tearDownWithError() throws {
        window = nil
        controller = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// Writes the stats fixture file ("Hello world\nThis is line 2\n":
    /// 27 chars, 27 bytes of ASCII, 3 lines, 6 words) and opens it as a
    /// tab, returning the document.
    private func openFixtureDocument() throws -> DocumentModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-summary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hello.txt")
        try Data("Hello world\nThis is line 2\n".utf8).write(to: file)
        controller.openFile(atPath: file.path)
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertEqual(doc.name, "hello.txt")
        XCTAssertEqual(doc.filePath?.path, file.path)
        XCTAssertEqual(doc.text, "Hello world\nThis is line 2\n")
        return doc
    }

    // MARK: - Report

    func testSummaryReportForFixtureFileBackedDocument() throws {
        let doc = try openFixtureDocument()
        let report = SummaryWindowController.summaryReport(activeController: controller)

        XCTAssertTrue(report.contains("File: hello.txt"), report)
        XCTAssertTrue(report.contains("Path: \(doc.filePath!.path)"), report)
        XCTAssertTrue(report.contains("Characters: \(doc.text.count)"), report)
        XCTAssertTrue(report.contains("Characters: 27"), report)
        XCTAssertTrue(report.contains("Bytes: \(doc.text.utf8.count)"), report)
        XCTAssertTrue(report.contains("Bytes: 27"), report)
        XCTAssertTrue(report.contains("Lines: \(GutterGeometry.lineCount(in: doc.text))"), report)
        XCTAssertTrue(report.contains("Lines: 3"), report)
        XCTAssertTrue(report.contains("Words: 6"), report)
        XCTAssertTrue(report.contains("Selection: 0 chars, 0 lines"), report)
        XCTAssertTrue(report.contains("Encoding: \(doc.encoding)"), report)
        XCTAssertTrue(report.contains("EOL: \(doc.eolType)"), report)
        XCTAssertTrue(report.contains("Type: \(doc.language)"), report)
    }

    func testSummaryReportForUntitledDocument() throws {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertNil(doc.filePath)
        let report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("File: Untitled"), report)
        XCTAssertTrue(report.contains("Path: (untitled)"), report)
    }

    func testSummaryReportWordCountUsesWhitespaceSplit() throws {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "  one  two\tthree\nfour   five  ")
        let report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Words: 5"), report)
    }

    func testSummaryReportDegradesWhenControllerIsNil() {
        let report = SummaryWindowController.summaryReport(activeController: nil)
        XCTAssertTrue(report.contains("File: (none)"), report)
        XCTAssertTrue(report.contains("Path: (none)"), report)
        XCTAssertTrue(report.contains("Characters: 0"), report)
        XCTAssertTrue(report.contains("Bytes: 0"), report)
        XCTAssertTrue(report.contains("Lines: 0"), report)
        XCTAssertTrue(report.contains("Words: 0"), report)
    }

    // MARK: - Selection stats

    func testSelectionStatsFollowTheEditorSelection() throws {
        _ = try openFixtureDocument()
        let textView = try XCTUnwrap(controller.editorTextView)

        // A one-line selection: 5 chars on line 1.
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        var report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Selection: 5 chars, 1 lines"), report)

        // A two-line selection: 12 chars spanning lines 1–2.
        textView.setSelectedRange(NSRange(location: 0, length: 12))
        report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Selection: 12 chars, 2 lines"), report)

        // No selection: zeros.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Selection: 0 chars, 0 lines"), report)
    }
}
