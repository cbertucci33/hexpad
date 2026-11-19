import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// M22a: Macro > Run a Macro Multiple Times… — the replay core
/// (``MainWindowController/runMacroMultipleTimes(count:untilEOF:)``) and its
/// validation/menu wiring. Mirrors the MacroUITests harness; the alert
/// dialog is the untested seam.
final class MacroRepeatTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Keep tests away from the developer's real macros.json and
        // keybindings.json (the menu builder in the validation/wiring tests
        // resolves both).
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-macro-repeat-tests-\(UUID().uuidString)")
        MacroStore.overrideDirectory = directory
        KeybindingStore.overrideDirectory = directory
    }

    override func tearDownWithError() throws {
        MacroStore.overrideDirectory = nil
        KeybindingStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    /// Records one duplicate-line command and stops, leaving a one-step macro
    /// on the controller (same shape as MacroUITests' helper).
    private func recordDuplicateLine(in controller: MainWindowController) throws {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: "a")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.startMacroRecording()
        XCTAssertTrue(controller.performCommand(identifier: "duplicate-line"))
        controller.stopMacroRecording()
        XCTAssertEqual(try XCTUnwrap(controller.lastMacro).steps,
                       [MacroStep(identifier: "duplicate-line")])
    }

    private func resetBuffer(in controller: MainWindowController, to text: String) throws {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: text)
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: - Core

    func testCountThreeReplaysFixtureMacroThreeTimes() throws {
        let (controller, _) = makeController()
        try recordDuplicateLine(in: controller)
        try resetBuffer(in: controller, to: "a")

        controller.runMacroMultipleTimes(count: 3, untilEOF: false)

        XCTAssertEqual(controller.lastMacroRepeatPasses, 3)
        // duplicate-line appends one line per pass: 1 + 3 = 4 lines.
        XCTAssertEqual(GutterGeometry.lineCount(in: try XCTUnwrap(controller.tabStore.selectedDocument).text), 4)
    }

    func testUntilEOFStopsWhenDocumentStopsChanging() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: "abc")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        controller.startMacroRecording()
        XCTAssertTrue(controller.performCommand(identifier: "uppercase"))
        controller.stopMacroRecording()
        XCTAssertEqual(try XCTUnwrap(controller.lastMacro).steps, [MacroStep(identifier: "uppercase")])

        try resetBuffer(in: controller, to: "abc")
        textView.setSelectedRange(NSRange(location: 0, length: 3))

        // The uppercase pass changes the text once; the next pass is a no-op
        // and ends the loop.
        controller.runMacroMultipleTimes(count: 0, untilEOF: true)
        XCTAssertEqual(doc.text, "ABC")
        XCTAssertEqual(controller.lastMacroRepeatPasses, 2)
    }

    func testUntilEOFReplaysDuplicateLineToTheCap() throws {
        let (controller, _) = makeController()
        try recordDuplicateLine(in: controller)
        try resetBuffer(in: controller, to: "a")

        controller.runMacroMultipleTimes(count: 0, untilEOF: true)

        XCTAssertEqual(controller.lastMacroRepeatPasses, MainWindowController.macroRepeatEOFCap)
        // duplicate-line appends one line per pass: 1 + cap = 1001 lines.
        XCTAssertEqual(GutterGeometry.lineCount(in: try XCTUnwrap(controller.tabStore.selectedDocument).text),
                       MainWindowController.macroRepeatEOFCap + 1)
    }

    // MARK: - Validation and menu wiring

    func testValidationRequiresRecordedMacroAndDocument() throws {
        let (controller, _) = makeController()
        let item = NSMenuItem(title: "Run a Macro Multiple Times…",
                              action: #selector(MainWindowController.showRunMacroMultipleTimesDialog(_:)),
                              keyEquivalent: "")
        // Idle, nothing recorded: disabled.
        XCTAssertFalse(controller.validateMenuItem(item))

        // Recorded macro + open document: enabled.
        try recordDuplicateLine(in: controller)
        XCTAssertTrue(controller.validateMenuItem(item))

        // No document: disabled again.
        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    func testMacroMenuHasRunMultipleTimesAfterPlayLastMacro() throws {
        let delegate = HexpadAppDelegate()
        let macroMenu = try XCTUnwrap(delegate.buildMainMenu().item(withTitle: "Macro")?.submenu)
        let titles = macroMenu.items.map(\.title)
        let index = try XCTUnwrap(titles.firstIndex(of: "Run a Macro Multiple Times…"),
                                  "the item exists")
        XCTAssertEqual(titles[index - 1], "Play Last Macro")
        let item = macroMenu.items[index]
        XCTAssertNil(item.target, "macro actions resolve through the responder chain")
        XCTAssertEqual(item.action, #selector(MainWindowController.showRunMacroMultipleTimesDialog(_:)))
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
