import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Coverage for the Macro menu layer: the store's tolerance and persistence,
/// recording through the single `performCommand` capture point, replay as one
/// undoable edit, and the enabled/disabled state of every Macro menu item.
final class MacroUITests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Keep tests away from the developer's real macros.json and
        // keybindings.json (the menu builder resolves both).
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-macro-tests-\(UUID().uuidString)")
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

    // MARK: - Helpers

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    private func macroMenu(from delegate: HexpadAppDelegate = HexpadAppDelegate()) throws -> NSMenu {
        let menu = delegate.buildMainMenu()
        let item = try XCTUnwrap(menu.item(withTitle: "Macro"))
        return try XCTUnwrap(item.submenu)
    }

    /// Records one duplicate-line command and stops, leaving a one-step macro.
    private func recordDuplicateLine(in controller: MainWindowController) throws {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: "alpha\nbeta")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        controller.startMacroRecording()
        XCTAssertTrue(controller.performCommand(identifier: "duplicate-line"))
        controller.stopMacroRecording()
    }

    // MARK: - Store round-trip / relaunch

    func testMacroStoreRoundTripSurvivesRelaunch() throws {
        let macro = MacroModel(name: "Dup and comment", steps: [
            MacroStep(identifier: "duplicate-line"),
            MacroStep(identifier: "toggle-line-comment", parameter: "# ")
        ])
        try MacroStore.set(macro)

        XCTAssertEqual(MacroStore.macrosFileURL.lastPathComponent, "macros.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MacroStore.macrosFileURL.path))

        // A fresh load stands in for a relaunch: the store keeps no in-memory
        // state, so decoding the file is the whole restore path.
        XCTAssertEqual(MacroStore.load(), [macro])
        XCTAssertEqual(MacroStore.macro(named: "Dup and comment"), macro)

        // Saving the same name replaces the previous definition rather than
        // appending a duplicate row to the menu.
        let replacement = MacroModel(name: "Dup and comment",
                                     steps: [MacroStep(identifier: "uppercase")])
        try MacroStore.set(replacement)
        XCTAssertEqual(MacroStore.load(), [replacement])

        try MacroStore.remove(named: "Dup and comment")
        XCTAssertTrue(MacroStore.load().isEmpty)
        XCTAssertNil(MacroStore.macro(named: "Dup and comment"))
    }

    func testMalformedMacroFileDegradesToEmptyAndSkipsBadEntries() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Entirely malformed file: no macros, no throw on the menu path.
        try Data("{ this is not json".utf8).write(to: MacroStore.macrosFileURL)
        XCTAssertTrue(MacroStore.load().isEmpty)
        XCTAssertNil(MacroStore.macro(named: "anything"))

        // A mix of valid and malformed entries keeps only the valid ones.
        let json = """
        [
          { "name": "Good", "steps": [{ "identifier": "duplicate-line" }] },
          { "name": 42 },
          "not a macro",
          { "steps": [{ "identifier": "uppercase" }] }
        ]
        """
        try Data(json.utf8).write(to: MacroStore.macrosFileURL)

        let loaded = MacroStore.load()
        XCTAssertEqual(loaded.map(\.name), ["Good", "Macro"])
        XCTAssertEqual(loaded.first?.steps, [MacroStep(identifier: "duplicate-line")])
    }

    // MARK: - Record then play

    func testRecordedMacroReplaysSameTransformationAsOneUndoStep() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "alpha\nbeta\ngamma")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        controller.startMacroRecording()
        XCTAssertTrue(controller.isRecordingMacro)
        // Programmatic text changes are not commands, so they never record.
        doc.replaceAllText(with: "alpha\nbeta\ngamma")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "duplicate-line"))
        XCTAssertTrue(controller.performCommand(identifier: "move-line-down"))
        controller.stopMacroRecording()

        let macro = try XCTUnwrap(controller.lastMacro)
        XCTAssertEqual(macro.steps, [MacroStep(identifier: "duplicate-line"),
                                     MacroStep(identifier: "move-line-down")])
        let recordedText = doc.text
        let recordedSelection = textView.selectedRange
        XCTAssertEqual(recordedText, "alpha\nbeta\nalpha\ngamma")

        // Reset to the pre-recording state, then replay.
        doc.replaceAllText(with: "alpha\nbeta\ngamma")
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.playMacro(macro))
        XCTAssertEqual(doc.text, recordedText)
        XCTAssertEqual(textView.selectedRange, recordedSelection)

        // The whole replay is one undoable edit on the document's stack.
        doc.undoManager.undo()
        XCTAssertEqual(doc.text, "alpha\nbeta\ngamma")
    }

    func testPlayReportsSkippedStepsWithoutBlockingTheRest() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "alpha\nbeta")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let macro = MacroModel(name: "Mixed", steps: [
            MacroStep(identifier: "not-a-command"),
            MacroStep(identifier: "duplicate-line")
        ])
        XCTAssertTrue(controller.playMacro(macro))
        XCTAssertEqual(doc.text, "alpha\nalpha\nbeta")
    }

    func testPlayedSavedMacroReadsFromStore() throws {
        let (controller, _) = makeController()
        try recordDuplicateLine(in: controller)
        try controller.saveRecording(named: "Duplicate")

        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: "alpha\nbeta")
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let item = NSMenuItem(title: "Duplicate",
                              action: #selector(MainWindowController.playSavedMacro(_:)),
                              keyEquivalent: "")
        item.representedObject = "Duplicate"
        controller.playSavedMacro(item)

        XCTAssertEqual(doc.text, "alpha\nalpha\nbeta")
        doc.undoManager.undo()
        XCTAssertEqual(doc.text, "alpha\nbeta")
    }

    // MARK: - Menu construction and validation

    func testMacroMenuHasEveryEntryAndNoParallelActions() throws {
        let macroMenu = try macroMenu()

        XCTAssertEqual(macroMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Record Macro", "Stop Recording", "Play Last Macro",
                        "Run a Macro Multiple Times…",
                        "Play Macro", "Save Recording As…", "Delete Macro"])

        for item in macroMenu.items where !item.isSeparatorItem && item.submenu == nil {
            XCTAssertNil(item.target, "macro actions resolve through the responder chain")
        }

        let record = try XCTUnwrap(macroMenu.item(withTitle: "Record Macro"))
        XCTAssertEqual(record.action, #selector(MainWindowController.toggleMacroRecording(_:)))
        let stop = try XCTUnwrap(macroMenu.item(withTitle: "Stop Recording"))
        XCTAssertEqual(stop.action, #selector(MainWindowController.stopRecordingMacro(_:)))
        let playLast = try XCTUnwrap(macroMenu.item(withTitle: "Play Last Macro"))
        XCTAssertEqual(playLast.action, #selector(MainWindowController.playLastMacro(_:)))
        let save = try XCTUnwrap(macroMenu.item(withTitle: "Save Recording As…"))
        XCTAssertEqual(save.action, #selector(MainWindowController.saveRecordingAs(_:)))

        // Empty stores show a disabled placeholder in both name lists.
        for title in ["Play Macro", "Delete Macro"] {
            let submenu = try XCTUnwrap(macroMenu.item(withTitle: title)?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), ["No Saved Macros"])
            XCTAssertFalse(try XCTUnwrap(submenu.items.first).isEnabled)
        }
    }

    func testRecordingMenuItemsReflectLiveRecordingState() throws {
        let macroMenu = try macroMenu()
        let record = try XCTUnwrap(macroMenu.item(withTitle: "Record Macro"))
        let stop = try XCTUnwrap(macroMenu.item(withTitle: "Stop Recording"))
        let playLast = try XCTUnwrap(macroMenu.item(withTitle: "Play Last Macro"))
        let save = try XCTUnwrap(macroMenu.item(withTitle: "Save Recording As…"))

        let (controller, _) = makeController()

        // Idle, empty recorder: only Record Macro is available.
        XCTAssertTrue(controller.validateMenuItem(record))
        XCTAssertEqual(record.state, .off)
        XCTAssertFalse(controller.validateMenuItem(stop))
        XCTAssertFalse(controller.validateMenuItem(playLast))
        XCTAssertFalse(controller.validateMenuItem(save))

        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)
        doc.replaceAllText(with: "alpha\nbeta")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        controller.startMacroRecording()
        XCTAssertTrue(controller.validateMenuItem(record))
        XCTAssertEqual(record.state, .on, "the checkmark mirrors the recording state")
        XCTAssertTrue(controller.validateMenuItem(stop))

        XCTAssertTrue(controller.performCommand(identifier: "duplicate-line"))
        XCTAssertTrue(controller.validateMenuItem(save), "a non-empty recording can be saved")

        controller.stopMacroRecording()
        XCTAssertTrue(controller.validateMenuItem(record))
        XCTAssertEqual(record.state, .off)
        XCTAssertFalse(controller.validateMenuItem(stop), "Stop Recording is only live while recording")
        XCTAssertTrue(controller.validateMenuItem(playLast))
        XCTAssertTrue(controller.validateMenuItem(save))

        // No document means no replay target; the recording itself is untouched.
        controller.tabStore.documents.removeAll()
        XCTAssertFalse(controller.validateMenuItem(playLast))
        XCTAssertTrue(controller.validateMenuItem(save))
    }

    func testSavedMacroSubmenuTracksStoreAndValidates() throws {
        let (controller, _) = makeController()
        try recordDuplicateLine(in: controller)
        try controller.saveRecording(named: "Duplicate")

        let delegate = HexpadAppDelegate()
        let macroMenu = try macroMenu(from: delegate)
        let playSubmenu = try XCTUnwrap(macroMenu.item(withTitle: "Play Macro")?.submenu)
        let deleteSubmenu = try XCTUnwrap(macroMenu.item(withTitle: "Delete Macro")?.submenu)

        delegate.menuNeedsUpdate(playSubmenu)
        let playItem = try XCTUnwrap(playSubmenu.items.first {
            ($0.representedObject as? String) == "Duplicate"
        })
        XCTAssertEqual(playItem.action, #selector(MainWindowController.playSavedMacro(_:)))
        XCTAssertNil(playItem.target)
        XCTAssertTrue(controller.validateMenuItem(playItem))

        delegate.menuNeedsUpdate(deleteSubmenu)
        let deleteItem = try XCTUnwrap(deleteSubmenu.items.first {
            ($0.representedObject as? String) == "Duplicate"
        })
        XCTAssertEqual(deleteItem.action, #selector(MainWindowController.deleteMacro(_:)))
        XCTAssertTrue(controller.validateMenuItem(deleteItem))

        // A macro with no steps cannot be played but can be deleted.
        try MacroStore.set(MacroModel(name: "Empty"))
        delegate.menuNeedsUpdate(playSubmenu)
        delegate.menuNeedsUpdate(deleteSubmenu)
        let emptyPlay = try XCTUnwrap(playSubmenu.items.first {
            ($0.representedObject as? String) == "Empty"
        })
        XCTAssertFalse(controller.validateMenuItem(emptyPlay))
        let emptyDelete = try XCTUnwrap(deleteSubmenu.items.first {
            ($0.representedObject as? String) == "Empty"
        })
        XCTAssertTrue(controller.validateMenuItem(emptyDelete))

        // Deletion updates the store and the next menu refresh.
        controller.deleteMacro(deleteItem)
        XCTAssertNil(MacroStore.macro(named: "Duplicate"))
        delegate.menuNeedsUpdate(playSubmenu)
        XCTAssertFalse(playSubmenu.items.contains { ($0.representedObject as? String) == "Duplicate" })
    }

    func testSaveRecordingNamedPersistsAcrossFreshLoad() throws {
        let (controller, _) = makeController()
        try recordDuplicateLine(in: controller)

        let saved = try XCTUnwrap(try controller.saveRecording(named: "  Duplicate  "))
        XCTAssertEqual(saved.name, "Duplicate", "the name is trimmed before saving")
        XCTAssertEqual(MacroStore.load().map(\.name), ["Duplicate"])
        XCTAssertFalse(saved.isRecording, "recordings never persist as recording")
    }

    // MARK: - Tools/Line Ops/View commands through the capture point

    func testRecordedDateTimeReplaysAtCaret() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "start ")
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        controller.startMacroRecording()
        XCTAssertTrue(controller.performCommand(identifier: "insert-datetime"))
        controller.stopMacroRecording()

        let macro = try XCTUnwrap(controller.lastMacro)
        XCTAssertEqual(macro.steps, [MacroStep(identifier: "insert-datetime")])
        XCTAssertNotNil(doc.text.range(
            of: #"^start \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#,
            options: .regularExpression
        ))

        // Reset and replay. The timestamp is read at execution time, so this
        // asserts the shape rather than the recorded value.
        doc.replaceAllText(with: "start ")
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        XCTAssertTrue(controller.playMacro(macro))
        XCTAssertNotNil(doc.text.range(
            of: #"^start \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#,
            options: .regularExpression
        ))
        XCTAssertEqual(textView.selectedRange.length, 0)
        XCTAssertEqual(textView.selectedRange.location, (doc.text as NSString).length)

        doc.undoManager.undo()
        XCTAssertEqual(doc.text, "start ", "the whole replay is one undoable edit")
    }

    func testRecordedHashCommandReplaysTheSameDigest() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "abc\n")
        textView.setSelectedRange(NSRange(location: 0, length: 3))

        controller.startMacroRecording()
        XCTAssertTrue(controller.performCommand(identifier: "hash-md5"))
        controller.stopMacroRecording()

        let macro = try XCTUnwrap(controller.lastMacro)
        XCTAssertEqual(macro.steps, [MacroStep(identifier: "hash-md5")])
        let expected = HashKit.md5("abc") + "abc\n"
        XCTAssertEqual(doc.text, expected)

        doc.replaceAllText(with: "abc\n")
        doc.undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 3))

        XCTAssertTrue(controller.playMacro(macro))
        XCTAssertEqual(doc.text, expected)
        XCTAssertEqual(textView.selectedRange,
                       NSRange(location: HashKit.md5("abc").count, length: 0))
    }

    func testRecordedFoldAllIsCapturedButPureTextReplaySkipsIt() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let editor = try XCTUnwrap(PreferencesApplier.editorContainer(in: controller.view))

        doc.setLanguage(Language.swift.rawValue)
        doc.replaceAllText(with: "outer {\n    inner {\n        x\n    }\n}\ntail\n")
        controller.updateEditor()

        controller.startMacroRecording()
        controller.foldAll(nil)
        controller.stopMacroRecording()

        let macro = try XCTUnwrap(controller.lastMacro)
        XCTAssertEqual(macro.steps, [MacroStep(identifier: "fold-all")],
                       "Fold All is now captured through performCommand")
        XCTAssertEqual(doc.foldState.count, 2)
        XCTAssertEqual(editor.foldMarkers[1], .collapsed)

        // Reset the view state without recording, then replay the macro. Fold
        // state is view state, not DocumentState: replay reports the step as
        // skipped instead of silently claiming it ran.
        controller.unfoldAll(nil)
        XCTAssertTrue(doc.foldState.isEmpty)
        XCTAssertEqual(editor.foldMarkers[1], .expanded)

        XCTAssertFalse(controller.playMacro(macro), "a view-only step changes no document text")
        XCTAssertTrue(doc.foldState.isEmpty, "pure text replay cannot restore fold state")
    }

    func testReplayDuringRecordingDoesNotAppendItsOwnSteps() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "alpha\nbeta")
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        controller.startMacroRecording()
        XCTAssertTrue(controller.performCommand(identifier: "duplicate-line"))
        XCTAssertEqual(controller.macroRecorder.stepCount, 1)

        // Replay the in-progress recording while the recorder is still live.
        let inProgress = controller.macroRecorder
        _ = controller.playMacro(inProgress)

        XCTAssertEqual(controller.macroRecorder.stepCount, 1,
                       "replay must not feed its steps back into the recording")
        XCTAssertEqual(controller.macroRecorder.steps,
                       [MacroStep(identifier: "duplicate-line")])

        // The recorder is still live for genuine user commands afterwards.
        XCTAssertTrue(controller.performCommand(identifier: "delete-line"))
        XCTAssertEqual(controller.macroRecorder.stepCount, 2)
        controller.stopMacroRecording()
    }
}
