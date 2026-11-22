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
        // Wave 5B: "Characters" excludes EOLs; the raw count moved to its own row.
        XCTAssertTrue(report.contains("Characters: \(SummaryWindowController.characterCount(excludingEOLs: doc.text))"), report)
        XCTAssertTrue(report.contains("Characters: 25"), report)
        XCTAssertTrue(report.contains("Characters (with EOLs): \(doc.text.count)"), report)
        XCTAssertTrue(report.contains("Characters (with EOLs): 27"), report)
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

    // MARK: - Size on disk / menu placement

    func testSummaryReportShowsActualSizeOnDisk() throws {
        let doc = DocumentModel(text: "Hello\n")
        controller.tabStore.addDocument(doc)
        let file = try temporaryFileURL(named: "size-on-disk.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try doc.saveAs(to: file)

        XCTAssertEqual(try XCTUnwrap(SummaryWindowController.fileSizeOnDisk(of: doc)), 6)
        let report = SummaryWindowController.summaryReport(activeController: controller)
        XCTAssertTrue(report.contains("Size on disk: 6 bytes"), report)
    }

    func testSizeOnDiskIsNilForUntitledDocument() {
        let doc = DocumentModel(text: "scratch")
        XCTAssertNil(SummaryWindowController.fileSizeOnDisk(of: doc))
    }

    /// V19g/V19h: both utilities live in the Tools menu, nil-targeted so the
    /// controller owns validation and the per-document checkmark.
    func testToolsMenuHasMonitorFileAndDocumentSummary() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let tools = try XCTUnwrap(menu.item(withTitle: "Tools")?.submenu)

        let monitor = try XCTUnwrap(tools.items.first { $0.title == "Monitor File" })
        XCTAssertTrue(monitor.action == #selector(MainWindowController.toggleFileMonitoring(_:)))
        XCTAssertNil(monitor.target)

        let summary = try XCTUnwrap(tools.items.first { $0.title == "Document Summary" })
        XCTAssertTrue(summary.action == #selector(MainWindowController.showSummary(_:)))
        XCTAssertNil(summary.target)
    }

    // MARK: - Bytes

    /// Writes to a fresh temp file via the public save path and returns the
    /// URL; the caller owns cleanup of the containing directory.
    private func temporaryFileURL(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-summary-bytes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func testSummaryBytesMatchesSavedFileForUTF16Fixture() throws {
        // A UTF-16LE doc with a BOM: "Bytes" counts the bytes a save writes
        // (BOM + 2 per code unit), not the UTF-8 size of the buffer.
        let doc = DocumentModel(text: "caf\u{e9} = 42\n", encoding: "UTF-16LE")
        doc.keepsBOM = true
        controller.tabStore.addDocument(doc)
        let file = try temporaryFileURL(named: "fixture-utf16.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try doc.saveAs(to: file)

        let actual = try XCTUnwrap(Data(contentsOf: file).count)
        XCTAssertGreaterThan(actual, doc.text.utf8.count,
                             "the UTF-16 file holds more bytes than the UTF-8 buffer")
        XCTAssertEqual(actual, SummaryWindowController.onDiskByteCount(of: doc),
                       "the reported byte count matches the saved file's size")
        XCTAssertTrue(SummaryWindowController.summaryReport(activeController: controller)
                          .contains("Bytes: \(actual)"),
                      "the report shows the on-disk byte count")
    }

    func testSummaryBytesMatchesSavedFileForCRLFFixture() throws {
        // A doc whose next save writes CRLF: the buffer is LF, so the old
        // text.utf8.count undercounted by the line endings.
        let doc = DocumentModel(text: "first line\nsecond line\n", eolType: EOLDetective.crlf)
        controller.tabStore.addDocument(doc)
        let file = try temporaryFileURL(named: "fixture-crlf.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try doc.saveAs(to: file)

        let actual = try XCTUnwrap(Data(contentsOf: file).count)
        XCTAssertEqual(actual, "first line\r\nsecond line\r\n".utf8.count)
        XCTAssertEqual(actual, SummaryWindowController.onDiskByteCount(of: doc))
        XCTAssertTrue(SummaryWindowController.summaryReport(activeController: controller)
                          .contains("Bytes: \(actual)"),
                      "the report shows the on-disk byte count")
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
