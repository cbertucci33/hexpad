import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Coverage for the Run… dialog: placeholder context built from a live
/// document, the saved-command store's persistence and tolerance, the policy
/// timeout reaching the runner, and the Run menu's validation.
final class RunCommandTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Menu construction resolves keybindings and macros; the Run dialog
        // reads runcommands.json. None of it may touch the developer's files.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-run-tests-\(UUID().uuidString)")
        RunCommandStore.overrideDirectory = directory
        KeybindingStore.overrideDirectory = directory
        MacroStore.overrideDirectory = directory
    }

    override func tearDownWithError() throws {
        RunCommandStore.overrideDirectory = nil
        KeybindingStore.overrideDirectory = nil
        MacroStore.overrideDirectory = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Placeholder context

    func testContextCombinesCurrentPathWithCaretLineIndex() throws {
        let path = URL(fileURLWithPath: "/tmp/hexpad-run-context.md")
        let doc = DocumentModel(text: "alpha\nbeta\ngamma", filePath: path)

        XCTAssertEqual(RunCommandWindowController.context(for: doc, caretLocation: 0),
                       ExternalCommandContext(filePath: path.path, lineNumber: 1))
        XCTAssertEqual(RunCommandWindowController.context(for: doc, caretLocation: 6).lineNumber, 2)
        XCTAssertEqual(RunCommandWindowController.context(for: doc, caretLocation: 999).lineNumber, 3,
                       "a caret past the end clamps to the last line, like the status bar")
        XCTAssertEqual(RunCommandWindowController.context(for: doc, caretLocation: -4).lineNumber, 1)

        // The context feeds the runner's documented placeholders unchanged.
        let context = RunCommandWindowController.context(for: doc, caretLocation: 6)
        XCTAssertEqual(ExternalCommandRunner.substitute(
            "wc -l \"$(FULL_CURRENT_PATH)\" # $(FILE_NAME) line $(CURRENT_LINE)", in: context),
            "wc -l \"/tmp/hexpad-run-context.md\" # hexpad-run-context.md line 2")
    }

    func testContextKeepsLineForUntitledDocumentsAndUsesCurrentCaret() throws {
        let untitled = DocumentModel(text: "one\ntwo")
        let context = RunCommandWindowController.context(for: untitled, caretLocation: 4)
        XCTAssertNil(context.filePath)
        XCTAssertEqual(context.lineNumber, 2)

        // The panel resolves its context through the provider at Run time.
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: "a\nb\nc")
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        let resolved = controller.currentCommandContext()
        XCTAssertNil(resolved.filePath, "the default tab is untitled")
        XCTAssertEqual(resolved.lineNumber, 2)
    }

    // MARK: - Saved commands

    func testSavedCommandStoreRoundTripsAndKeepsNewestTen() throws {
        try RunCommandStore.add(SavedRunCommand(name: "First", command: "echo first"))
        try RunCommandStore.add(SavedRunCommand(name: "Second", command: "echo second"))
        try RunCommandStore.add(SavedRunCommand(name: "Third", command: "echo third"))

        XCTAssertEqual(RunCommandStore.commandsFileURL.lastPathComponent, "runcommands.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RunCommandStore.commandsFileURL.path))
        XCTAssertEqual(RunCommandStore.load().map(\.name), ["Third", "Second", "First"],
                       "most recently saved comes first")

        // Re-saving the same name replaces it instead of duplicating the entry.
        try RunCommandStore.add(SavedRunCommand(name: "Second", command: "echo replaced"))
        XCTAssertEqual(RunCommandStore.load().map(\.command),
                       ["echo replaced", "echo third", "echo first"])
        XCTAssertEqual(RunCommandStore.command(named: "Second")?.command, "echo replaced")

        // A blank name falls back to the command text instead of being dropped.
        try RunCommandStore.add(SavedRunCommand(name: "   ", command: "date"))
        XCTAssertEqual(RunCommandStore.command(named: "date")?.command, "date")

        // The list is capped at ten, dropping the oldest entries.
        for index in 0..<12 {
            try RunCommandStore.add(SavedRunCommand(name: "Cmd \(index)", command: "echo \(index)"))
        }
        let capped = RunCommandStore.load()
        XCTAssertEqual(capped.count, RunCommandStore.maxSavedCommands)
        XCTAssertEqual(capped.count, 10)
        XCTAssertEqual(capped.first?.name, "Cmd 11")
        XCTAssertEqual(capped.last?.name, "Cmd 2")
        XCTAssertFalse(capped.contains { $0.name == "Cmd 0" })

        try RunCommandStore.remove(named: "Cmd 11")
        XCTAssertNil(RunCommandStore.command(named: "Cmd 11"))
        XCTAssertEqual(RunCommandStore.load().count, 9)
    }

    func testSavedCommandStoreToleratesMalformedFileAndSkipsBadEntries() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Entirely malformed file: no commands, no throw on the dialog path.
        try Data("{ not json".utf8).write(to: RunCommandStore.commandsFileURL)
        XCTAssertTrue(RunCommandStore.load().isEmpty)
        XCTAssertNil(RunCommandStore.command(named: "anything"))

        let json = """
        [
          { "name": "Good", "command": "echo good" },
          { "name": 42, "command": "echo bad name" },
          "not a command",
          { "command": "ls -l" },
          { "name": "Empty", "command": "   " },
          { "name": "No command key" },
          { "name": "Duplicate", "command": "echo good" }
        ]
        """
        try Data(json.utf8).write(to: RunCommandStore.commandsFileURL)

        let loaded = RunCommandStore.load()
        XCTAssertEqual(loaded.map(\.name), ["Good", "ls -l"],
                       "valid entries survive; a missing name falls back to the command")
        XCTAssertEqual(loaded.map(\.command), ["echo good", "ls -l"])
    }

    // MARK: - Policy timeout

    func testPolicyTimeoutIsThirtySeconds() {
        XCTAssertEqual(RunCommandPolicy.timeout, 30,
                       "the runner's indefinite default must not leak into the dialog")
    }

    func testLongRunningCommandIsTerminatedByTheDialogTimeout() throws {
        let controller = RunCommandWindowController()
        controller.commandTimeout = 0.2
        controller.contextProvider = { ExternalCommandContext() }

        let finished = expectation(description: "runner returned")
        var outcome: Result<ExternalCommandResult, ExternalCommandError>?
        let started = Date()

        controller.executeCommand("sleep 30") { result in
            outcome = result
            finished.fulfill()
        }

        XCTAssertTrue(controller.isRunning, "the dialog must show its running state")
        // Generous waits: the main queue can be busy behind the rest of the
        // suite, which must not decide this test. The elapsed bound below still
        // proves the 0.2 s policy fired instead of waiting out the 30 s sleep.
        wait(for: [finished], timeout: 30)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 20, "the 0.2 s policy must not wait for the 30 s sleep")
        XCTAssertFalse(controller.isRunning)

        let result = try XCTUnwrap(try outcome?.get())
        XCTAssertTrue(result.didTimeOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(controller.outputText.contains("Timed out"))
    }
    // MARK: - Buffer / undo isolation

    func testRunningACommandLeavesTheDocumentBufferAndUndoStackUntouched() throws {
        let doc = DocumentModel(text: "keep\nthis")
        doc.undoManager.removeAllActions()

        let controller = RunCommandWindowController()
        controller.contextProvider = {
            RunCommandWindowController.context(for: doc, caretLocation: 0)
        }

        let finished = expectation(description: "runner returned")
        controller.executeCommand("printf 'hello from the run dialog'") { _ in
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(doc.text, "keep\nthis", "the dialog only reads the document")
        XCTAssertFalse(doc.unsavedChanges)
        XCTAssertFalse(doc.undoManager.canUndo,
                       "running a shell command must not register an edit")

        XCTAssertTrue(controller.outputText.contains("hello from the run dialog"))
        XCTAssertTrue(controller.outputText.contains("Exit code: 0"))
        XCTAssertTrue(controller.outputText.contains("$ printf"))
    }

    func testFailureOutputKeepsStdoutAndStderrDistinct() throws {
        let controller = RunCommandWindowController()
        controller.contextProvider = { ExternalCommandContext() }

        let finished = expectation(description: "runner returned")
        controller.executeCommand("echo out; echo err 1>&2; exit 3") { _ in
            finished.fulfill()
        }
        // This test asserts output separation, never speed; a slow machine must
        // not fail it. The 30 s budget is load-tolerant headroom, not an
        // assertion.
        wait(for: [finished], timeout: 30)

        let text = controller.outputText
        XCTAssertTrue(text.contains("$ echo out"), "the expanded command is echoed")
        XCTAssertTrue(text.contains("out"))
        XCTAssertTrue(text.contains("stderr:\nerr"))
        XCTAssertTrue(text.contains("Exit code: 3"))
    }

    // MARK: - Menu wiring and validation

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    func testRunMenuOffersF5WithoutADocumentRequirementToBuild() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let runMenu = try XCTUnwrap(menu.item(withTitle: "Run")?.submenu)
        let item = try XCTUnwrap(runMenu.item(withTitle: "Run…"))

        XCTAssertEqual(item.keyEquivalent, "\u{F708}", "F5 follows the Notepad++ convention")
        XCTAssertEqual(item.keyEquivalentModifierMask, [], "plain F5, not Command+F5")
        XCTAssertEqual(item.action, #selector(MainWindowController.showRunCommandDialog(_:)))
        XCTAssertNil(item.target, "validation reaches the controller through the responder chain")
    }

    func testRunMenuItemIsDisabledWithoutADocument() throws {
        let (controller, _) = makeController()
        let item = NSMenuItem(title: "Run…",
                              action: #selector(MainWindowController.showRunCommandDialog(_:)),
                              keyEquivalent: "")

        XCTAssertTrue(controller.canRunCommand())
        XCTAssertTrue(controller.validateMenuItem(item))

        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.canRunCommand())
        XCTAssertFalse(controller.validateMenuItem(item),
                       "placeholder expansion needs a current document")

        let doc = DocumentModel(text: "back")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    func testRunDialogUsesOnePanelInstance() {
        let (controller, _) = makeController()
        let first = controller.runCommandPanel()
        let second = controller.runCommandPanel()
        XCTAssertTrue(first === second, "the menu reopens the same panel")
        XCTAssertNotNil(first.contextProvider, "the main controller installs the live context provider")
    }
}
