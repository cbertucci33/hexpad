import AppKit
import HexpadKit

/// One named entry in the Run dialog's saved-command list.
struct SavedRunCommand: Codable, Equatable {
    var name: String
    var command: String
}

/// Reads and writes the commands saved from the Run… dialog.
///
/// Entries live in `Application Support/Hexpad/runcommands.json`, next to
/// `session.json`, `keybindings.json` and `macros.json`. The file is a JSON
/// array, most recently saved first, capped at ``maxSavedCommands``:
///
/// ```json
/// [
///   { "name": "Word count", "command": "wc -w \"$(FULL_CURRENT_PATH)\"" }
/// ]
/// ```
///
/// Loading follows the same tolerant contract as ``MacroStore``: a missing,
/// unreadable, or malformed file yields no commands, and individual malformed
/// entries are skipped. An entry without a name is named after its command
/// text instead of being dropped, so a hand-edited file still appears in the
/// picker.
enum RunCommandStore {

    /// Test seam: when set, runcommands.json lives here instead of Application
    /// Support. Production never sets this; tests point it at a temp dir.
    static var overrideDirectory: URL?

    /// How many saved commands are kept. Saving an eleventh drops the oldest.
    static let maxSavedCommands = 10

    private static var appSupportDir: URL {
        if let override = overrideDirectory { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }

    static var commandsFileURL: URL {
        appSupportDir.appendingPathComponent("runcommands.json")
    }

    // MARK: - Loading

    /// Every well-formed saved command, in file order. Never throws: the Run
    /// dialog must open even when its history file is corrupt.
    static func load() -> [SavedRunCommand] {
        guard let data = try? Data(contentsOf: commandsFileURL),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let entries = raw as? [Any] else {
            return []
        }

        var commands: [SavedRunCommand] = []
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let rawCommand = object["command"] as? String else {
                continue
            }
            // A present-but-non-string name is malformed; only a missing name
            // falls back to the command text.
            if object.keys.contains("name"), !(object["name"] is String) {
                continue
            }

            let command = trimmed(rawCommand)
            guard !command.isEmpty else { continue }

            let rawName = trimmed(object["name"] as? String ?? "")
            let name = rawName.isEmpty ? command : rawName
            guard !commands.contains(where: { $0.name == name || $0.command == command }) else {
                continue
            }
            commands.append(SavedRunCommand(name: name, command: command))
            if commands.count == maxSavedCommands { break }
        }
        return commands
    }

    /// The saved command with this exact name, or `nil` when none is saved.
    static func command(named name: String) -> SavedRunCommand? {
        load().first { $0.name == name }
    }

    // MARK: - Saving

    /// Inserts `command` at the front, replacing any entry with the same name
    /// or the same command text, and trims the list to the newest
    /// ``maxSavedCommands`` entries. Returns the new saved list.
    @discardableResult
    static func add(_ command: SavedRunCommand) throws -> [SavedRunCommand] {
        let text = trimmed(command.command)
        guard !text.isEmpty else { return load() }
        let name = trimmed(command.name).isEmpty ? text : trimmed(command.name)

        var commands = load().filter { $0.name != name && $0.command != text }
        commands.insert(SavedRunCommand(name: name, command: text), at: 0)
        if commands.count > maxSavedCommands {
            commands.removeLast(commands.count - maxSavedCommands)
        }
        try save(commands)
        return commands
    }

    /// Removes the saved command with this name and returns the remaining list.
    @discardableResult
    static func remove(named name: String) throws -> [SavedRunCommand] {
        let commands = load().filter { $0.name != name }
        try save(commands)
        return commands
    }

    /// Replaces the whole saved list (used by tests and bulk edits).
    static func save(_ commands: [SavedRunCommand]) throws {
        try FileManager.default.createDirectory(at: appSupportDir,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(commands)
        try data.write(to: commandsFileURL, options: .atomic)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Timeout policy for commands launched from the Run… dialog.
///
/// ``ExternalCommandRunner`` waits indefinitely by default, which is right for
/// a library but wrong for a modal-ish panel: a command such as `tail -f`
/// would keep the dialog in its running state forever. The dialog therefore
/// always passes an explicit timeout; tests may lower it through
/// ``RunCommandWindowController/commandTimeout``.
enum RunCommandPolicy {
    /// Seconds the dialog waits before the runner terminates the command.
    static let timeout: TimeInterval = 30
}

/// Notepad++-style "Run…" panel: type a shell command, expand `$(...)`
/// placeholders against the current editor state, and show the command's
/// stdout/stderr and exit status in a read-only view.
///
/// Mirrors ``FindInFilesWindowController``/``FunctionListWindowController``:
/// a separate, resizable window, one instance reused for the lifetime of the
/// main window, and no interaction with the document's buffer or undo stack.
/// The command runs through ``ExternalCommandRunner`` on its private queue, so
/// the panel stays responsive while the process runs.
final class RunCommandWindowController: NSWindowController {

    /// Builds the placeholder context at run time. The main controller installs
    /// this closure so switching tabs (or moving the caret) between opening the
    /// panel and pressing Run resolves against the tab that is current *then*.
    var contextProvider: (() -> ExternalCommandContext)?

    /// Test seam for the policy timeout. Production leaves this at
    /// ``RunCommandPolicy/timeout`` (30 s).
    var commandTimeout: TimeInterval = RunCommandPolicy.timeout

    /// Commands shown by the picker, newest first. Exposed for app tests.
    private(set) var savedCommands: [SavedRunCommand] = []

    /// True while a subprocess is running; also disables the Run button.
    private(set) var isRunning = false

    /// What the read-only output view currently shows. Exposed for app tests.
    var outputText: String { outputTextView.string }

    private let commandField = NSTextField()
    private let commandPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Command…", target: nil, action: nil)
    private let outputTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    private static let pickerPlaceholder = "Saved Commands"

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Run"
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        self.init(window: window)
        buildUI()
        reloadSavedCommands()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true

        let hint = NSTextField(labelWithString:
            "$(FULL_CURRENT_PATH)  $(CURRENT_DIRECTORY)  $(FILE_NAME)  $(NAME_PART)  $(EXT_PART)  $(CURRENT_LINE)")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 12, y: 446, width: 676, height: 16)
        hint.autoresizingMask = [.width, .minYMargin]
        content.addSubview(hint)

        commandField.placeholderString = "Command to run, for example: wc -l \"$(FULL_CURRENT_PATH)\""
        commandField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.target = self
        commandField.action = #selector(runFromControls)
        commandField.frame = NSRect(x: 12, y: 414, width: 500, height: 24)
        commandField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(commandField)

        commandPicker.target = self
        commandPicker.action = #selector(chooseSavedCommand(_:))
        commandPicker.frame = NSRect(x: 520, y: 414, width: 168, height: 24)
        commandPicker.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(commandPicker)

        runButton.target = self
        runButton.action = #selector(runFromControls)
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded
        runButton.frame = NSRect(x: 604, y: 378, width: 84, height: 26)
        runButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(runButton)

        saveButton.target = self
        saveButton.action = #selector(saveCurrentCommand)
        saveButton.bezelStyle = .rounded
        saveButton.font = NSFont.systemFont(ofSize: 12)
        saveButton.frame = NSRect(x: 470, y: 378, width: 126, height: 26)
        saveButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(saveButton)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 34, width: 676, height: 336))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.isRichText = false
        outputTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        outputTextView.minSize = NSSize(width: 0, height: 0)
        outputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude)
        outputTextView.isVerticallyResizable = true
        outputTextView.isHorizontallyResizable = false
        outputTextView.autoresizingMask = [.width]
        outputTextView.textContainer?.widthTracksTextView = true
        outputTextView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                             height: .greatestFiniteMagnitude)
        scroll.documentView = outputTextView
        content.addSubview(scroll)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 12, y: 12, width: 560, height: 16)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)
    }

    override func showWindow(_ sender: Any?) {
        reloadSavedCommands()
        super.showWindow(sender)
        focusCommandField()
    }

    /// Puts the caret in the command field, so opening the panel is immediately
    /// typeable like Notepad++'s Run dialog.
    func focusCommandField() {
        window?.makeFirstResponder(commandField)
    }

    // MARK: - Saved commands

    /// Re-reads runcommands.json and rebuilds the picker. Called on every open
    /// and after a save so the menu always mirrors the file.
    func reloadSavedCommands() {
        savedCommands = RunCommandStore.load()

        commandPicker.removeAllItems()
        commandPicker.addItem(withTitle: Self.pickerPlaceholder)
        commandPicker.menu?.items.first?.isEnabled = false

        if savedCommands.isEmpty {
            let empty = NSMenuItem(title: "No Saved Commands", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            commandPicker.menu?.addItem(empty)
            return
        }

        for saved in savedCommands {
            let item = NSMenuItem(title: saved.name, action: nil, keyEquivalent: "")
            item.representedObject = saved.command
            commandPicker.menu?.addItem(item)
        }
    }

    @objc private func chooseSavedCommand(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard index >= 0, index < savedCommands.count else {
            sender.selectItem(at: 0)
            return
        }
        commandField.stringValue = savedCommands[index].command
        // Keep the popup showing its label; choosing the same entry again must
        // still fire the action.
        sender.selectItem(at: 0)
        focusCommandField()
    }

    @objc private func saveCurrentCommand() {
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            statusLabel.stringValue = "Type a command before saving it"
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save Command"
        alert.informativeText = "Name this command so it appears in the Run dialog's picker."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = command
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveCommand(command, named: field.stringValue)
    }

    /// Persists `command` under `name` and refreshes the picker. Exposed
    /// without the prompt so tests can save headlessly. A blank name falls back
    /// to the command text, matching the store's tolerance.
    @discardableResult
    func saveCommand(_ command: String, named name: String) -> SavedRunCommand? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedRunCommand(name: trimmedName.isEmpty ? text : trimmedName,
                                    command: text)
        do {
            try RunCommandStore.add(saved)
            reloadSavedCommands()
            statusLabel.stringValue = "Saved “\(saved.name)”"
            return saved
        } catch {
            statusLabel.stringValue = "Could not save command: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Running

    @objc private func runFromControls() {
        executeCommand(commandField.stringValue)
    }

    /// Runs `command` with the dialog's policy timeout and shows the result.
    ///
    /// The placeholder context is resolved *now*, not when the panel opened.
    /// The completion is delivered on the main queue after the output view and
    /// status label have been updated; tests use it to await the subprocess.
    func executeCommand(_ command: String,
                        completion: ((Result<ExternalCommandResult, ExternalCommandError>) -> Void)? = nil) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        isRunning = true
        runButton.isEnabled = false
        statusLabel.stringValue = "Running…"
        outputTextView.string = ""

        let context = contextProvider?() ?? ExternalCommandContext()
        let options = ExternalCommandOptions(timeout: commandTimeout)

        ExternalCommandRunner.run(trimmed, context: context, options: options) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.finish(outcome)
                completion?(outcome)
            }
        }
    }

    private func finish(_ outcome: Result<ExternalCommandResult, ExternalCommandError>) {
        isRunning = false
        runButton.isEnabled = true

        switch outcome {
        case .success(let result):
            outputTextView.string = Self.outputText(for: result)
            if result.didTimeOut {
                statusLabel.stringValue = "Timed out after \(Self.durationText(result.duration))"
            } else if result.succeeded {
                statusLabel.stringValue = "Finished"
            } else {
                statusLabel.stringValue = "Exited with code \(result.exitCode)"
            }
        case .failure(.launchFailed(let shell, let reason)):
            outputTextView.string = "Could not launch \(shell): \(reason)"
            statusLabel.stringValue = "Command did not start"
        }
    }

    // MARK: - Output formatting

    /// Renders one runner result for the read-only output view. stdout and
    /// stderr are kept visually distinct; the footer carries the exit code and
    /// duration (or the timeout notice).
    static func outputText(for result: ExternalCommandResult) -> String {
        var parts: [String] = ["$ \(result.command)"]

        if !result.standardOutput.isEmpty {
            parts.append(result.standardOutput)
        }
        if !result.standardError.isEmpty {
            parts.append("stderr:\n\(result.standardError)")
        }
        if result.standardOutput.isEmpty && result.standardError.isEmpty {
            parts.append("(no output)")
        }

        let duration = durationText(result.duration)
        if result.didTimeOut {
            parts.append("--- Timed out after \(duration) (exit \(result.exitCode)) ---")
        } else {
            parts.append("--- Exit code: \(result.exitCode) (\(duration)) ---")
        }
        return parts.joined(separator: "\n")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        String(format: "%.2f s", duration)
    }
}

// MARK: - Placeholder context

extension RunCommandWindowController {

    /// Builds the `$(...)` context from a document and a caret location.
    ///
    /// The line number comes from the same ``LineIndex`` the status bar caches
    /// (and the same one-based convention), so `$(CURRENT_LINE)` always agrees
    /// with the Ln label on screen. Only reads the model; nothing here mutates
    /// the document or its undo stack.
    static func context(for document: DocumentModel,
                        caretLocation: Int) -> ExternalCommandContext {
        let text = document.text
        let length = (text as NSString).length
        let caret = min(max(0, caretLocation), length)
        let line = LineIndex(text).line(of: caret)
        return ExternalCommandContext(filePath: document.filePath?.path,
                                      lineNumber: line)
    }
}
