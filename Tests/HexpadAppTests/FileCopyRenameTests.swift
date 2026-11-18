import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P16c / P16c-1: File > Print Now, Save a Copy As and Rename… .
///
/// Each command's NSSavePanel / NSPrintOperation is the only untested seam.
/// The URL-driven write and rename cores are exercised directly here, the way
/// the existing app tests drive controller helpers without running panels.
final class FileCopyRenameTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-file-copy-rename-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    private func select(_ doc: DocumentModel, in controller: MainWindowController) {
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
    }

    // MARK: - Save a Copy As

    func testSaveACopyWritesCurrentBufferWithoutRetargetingOrClearingDirty() throws {
        let originalURL = directory.appendingPathComponent("original.txt")
        let savedText = "saved line\n"
        try savedText.write(to: originalURL, atomically: true, encoding: .utf8)

        let doc = DocumentModel(text: savedText, filePath: originalURL)
        let controller = makeController()
        select(doc, in: controller)

        let buffer = savedText + "unsaved line\n"
        doc.replaceAllText(with: buffer)
        XCTAssertTrue(doc.unsavedChanges, "the fixture starts dirty")
        XCTAssertEqual(doc.filePath, originalURL)

        let copyURL = directory.appendingPathComponent("copy.txt")
        controller.saveACopy(to: copyURL) // URL-driven core; no NSSavePanel

        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), buffer,
                       "the copy holds the current buffer, not the saved file")
        XCTAssertEqual(doc.filePath, originalURL, "the open document keeps its own path")
        XCTAssertEqual(doc.name, "original.txt")
        XCTAssertTrue(doc.unsavedChanges, "the open document stays dirty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path),
                      "the original file is left in place")
    }

    func testSaveACopyIsByteFaithfulToTheNormalSaveEncoding() throws {
        let originalURL = directory.appendingPathComponent("encoded.txt")
        let text = "第一行\r\nsecond\r\n"
        let doc = DocumentModel(text: text, filePath: originalURL,
                                encoding: "UTF-8", eolType: "CRLF")
        doc.keepsBOM = true
        let controller = makeController()
        select(doc, in: controller)

        let copyURL = directory.appendingPathComponent("encoded-copy.txt")
        controller.saveACopy(to: copyURL)

        let data = try Data(contentsOf: copyURL)
        let bom = try XCTUnwrap(EncodingDetective.bomBytes(for: "UTF-8"),
                                "UTF-8 has a known BOM in the encoding table")
        XCTAssertTrue(data.starts(with: bom), "the BOM flag is re-emitted like Save")
        let body = Data(data.dropFirst(bom.count))
        XCTAssertEqual(String(data: body, encoding: .utf8), text,
                       "CRLF line endings survive the copy unchanged")
    }

    // MARK: - Rename

    func testRenameMovesFileUpdatesDocumentAndPreservesDirtyState() throws {
        let oldURL = directory.appendingPathComponent("old.txt")
        let savedText = "saved line\n"
        try savedText.write(to: oldURL, atomically: true, encoding: .utf8)

        let doc = DocumentModel(text: savedText, filePath: oldURL)
        let controller = makeController()
        select(doc, in: controller)
        doc.replaceAllText(with: savedText + "draft line\n")
        XCTAssertTrue(doc.unsavedChanges)

        let newURL = directory.appendingPathComponent("new.txt")
        controller.renameSelectedDocument(to: newURL) // URL-driven core; no NSSavePanel

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path),
                       "the old path is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path),
                      "the file exists at the new path")
        XCTAssertEqual(try String(contentsOf: newURL, encoding: .utf8), savedText,
                       "a rename does not silently save the dirty buffer")
        XCTAssertEqual(doc.filePath, newURL)
        XCTAssertEqual(doc.name, "new.txt")
        XCTAssertTrue(doc.unsavedChanges, "a dirty buffer stays dirty after rename")
    }

    func testRenameOnUntitledDocumentBehavesLikeSaveAs() throws {
        let controller = makeController()
        let doc = DocumentModel(text: "draft text\n")
        select(doc, in: controller)
        XCTAssertTrue(doc.isUntitled)

        let target = directory.appendingPathComponent("named.txt")
        controller.renameSelectedDocument(to: target)

        XCTAssertEqual(doc.filePath, target, "Save As assigns the chosen path")
        XCTAssertEqual(doc.name, "named.txt")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "draft text\n")
        XCTAssertFalse(doc.unsavedChanges, "a fresh buffer is clean after Save As")
    }

    // MARK: - Print validation

    func testPrintAndPrintNowShareValidation() {
        let controller = makeController()
        let printItem = NSMenuItem(title: "Print…",
                                   action: #selector(MainWindowController.printDocument(_:)),
                                   keyEquivalent: "")
        let nowItem = NSMenuItem(title: "Print Now",
                                 action: #selector(MainWindowController.printDocumentNow(_:)),
                                 keyEquivalent: "")

        XCTAssertTrue(controller.canPrintDocument())
        XCTAssertTrue(controller.validateMenuItem(printItem))
        XCTAssertTrue(controller.validateMenuItem(nowItem))

        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.canPrintDocument())
        XCTAssertFalse(controller.validateMenuItem(printItem))
        XCTAssertFalse(controller.validateMenuItem(nowItem),
                       "Print Now uses the same canPrintDocument() gate")
    }

    // MARK: - Menu wiring

    func testFileMenuWiresNewCommandsAfterTheirNeighbors() throws {
        let delegate = HexpadAppDelegate()
        let menu = delegate.makeFileMenu()
        let titles = menu.items.map(\.title)

        let saveAll = try XCTUnwrap(titles.firstIndex(of: "Save All"))
        XCTAssertEqual(titles[saveAll + 1], "Save a Copy As")
        XCTAssertEqual(titles[saveAll + 2], "Rename…")

        let print = try XCTUnwrap(titles.firstIndex(of: "Print…"))
        XCTAssertEqual(titles[print + 1], "Print Now")

        let copyItem = try XCTUnwrap(menu.item(withTitle: "Save a Copy As"))
        XCTAssertEqual(copyItem.action, #selector(HexpadAppDelegate.saveACopyAs(_:)))
        XCTAssertTrue(copyItem.target === delegate)

        let renameItem = try XCTUnwrap(menu.item(withTitle: "Rename…"))
        XCTAssertEqual(renameItem.action, #selector(HexpadAppDelegate.renameFile(_:)))
        XCTAssertTrue(renameItem.target === delegate)

        let printNowItem = try XCTUnwrap(menu.item(withTitle: "Print Now"))
        XCTAssertEqual(printNowItem.action, #selector(HexpadAppDelegate.printNow(_:)))
        XCTAssertTrue(printNowItem.target === delegate)
    }
}
