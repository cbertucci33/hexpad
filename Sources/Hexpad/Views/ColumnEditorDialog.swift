import AppKit
import HexpadKit

/// Parameters the focused controller's dialog chose for the Column Editor.
///
/// The dialog never edits a document: it only collects one of these values and
/// hands it to an `onApply` closure. `EditorContainer.applyColumnEditor` turns
/// the parameters into per-row insertions on the live column selection.
struct ColumnNumberParams: Equatable {
    var initial: Int
    var step: Int
    /// How many rows share one number before it advances (`repeat` in N++).
    var repeatCount: Int

    init(initial: Int = 1, step: Int = 1, repeatCount: Int = 1) {
        self.initial = initial
        self.step = step
        self.repeatCount = repeatCount
    }
}

enum ColumnEditorParameters: Equatable {
    case text(String)
    case numbers(ColumnNumberParams)

    /// The two option values `EditorContainer.applyColumnEditor` accepts.
    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var numbers: ColumnNumberParams? {
        if case .numbers(let value) = self { return value }
        return nil
    }
}

enum ColumnEditorMode: Equatable {
    case text
    case number
}

/// Notepad++-style Column Editor panel (Alt+C in N++).
///
/// The panel is built entirely in code so it is constructible headlessly: tests
/// set the mode and field properties directly and call ``collectParameters()``
/// or ``confirm(_:)`` without ordering a window on screen. OK sends the
/// collected parameters through ``onApply``; Cancel sends nothing. The main
/// window controller owns that closure and applies the edit to its editor, so
/// this type has no reference to a document or an `EditorContainer`.
final class ColumnEditorDialog: NSWindowController {

    /// Called by OK with the collected parameters. The controller installs it
    /// when it opens the one shared panel.
    var onApply: ((ColumnEditorParameters) -> Void)?

    private let textRadio: NSButton
    private let numberRadio: NSButton
    private let insertionField: NSTextField
    private let initialField: NSTextField
    private let stepField: NSTextField
    private let repeatField: NSTextField

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 252),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "Column Editor"
        panel.isFloatingPanel = false

        textRadio = NSButton(radioButtonWithTitle: "Text to insert",
                             target: nil, action: #selector(modeChanged(_:)))
        numberRadio = NSButton(radioButtonWithTitle: "Number to insert",
                               target: nil, action: #selector(modeChanged(_:)))
        insertionField = NSTextField(string: "")
        initialField = NSTextField(string: "1")
        stepField = NSTextField(string: "1")
        repeatField = NSTextField(string: "1")

        super.init(window: panel)
        for button in [textRadio, numberRadio] {
            button.target = self
        }
        buildUI(in: panel.contentView)
        mode = .text
    }

    required init?(coder: NSCoder) {
        fatalError("ColumnEditorDialog is built in code")
    }

    // MARK: - Fields
    //
    // The controls are the source of truth, so a headless property set and a
    // user typing into the field take exactly the same path into
    // `collectParameters()`.

    var mode: ColumnEditorMode {
        get { numberRadio.state == .on ? .number : .text }
        set {
            textRadio.state = newValue == .text ? .on : .off
            numberRadio.state = newValue == .number ? .on : .off
            updateFieldEnablement()
        }
    }

    var textToInsert: String {
        get { insertionField.stringValue }
        set { insertionField.stringValue = newValue }
    }

    var initialNumber: Int {
        get { Int(initialField.stringValue) ?? 0 }
        set { initialField.stringValue = String(newValue) }
    }

    var increaseBy: Int {
        get { Int(stepField.stringValue) ?? 0 }
        set { stepField.stringValue = String(newValue) }
    }

    var repeatCount: Int {
        get { Int(repeatField.stringValue) ?? 0 }
        set { repeatField.stringValue = String(newValue) }
    }

    /// The current field values, or `nil` when Text mode has nothing to insert.
    /// Number mode is always valid: a nonsensical numeric field reads as zero
    /// and the pure `numberSequence` clamps Repeat to at least one.
    func collectParameters() -> ColumnEditorParameters? {
        switch mode {
        case .text:
            return textToInsert.isEmpty ? nil : .text(textToInsert)
        case .number:
            return .numbers(ColumnNumberParams(initial: initialNumber,
                                               step: increaseBy,
                                               repeatCount: repeatCount))
        }
    }

    // MARK: - Actions

    @objc func confirm(_ sender: Any?) {
        guard let parameters = collectParameters() else { return }
        onApply?(parameters)
        dismiss()
    }

    @objc func cancel(_ sender: Any?) {
        dismiss()
    }

    @objc private func modeChanged(_ sender: Any?) {
        updateFieldEnablement()
    }

    /// Closing a never-shown panel is harmless, but skipping it keeps headless
    /// tests quiet and leaves nothing for AppKit to tear down.
    private func dismiss() {
        if window?.isVisible == true { close() }
    }

    private func updateFieldEnablement() {
        let isNumber = mode == .number
        insertionField.isEnabled = !isNumber
        initialField.isEnabled = isNumber
        stepField.isEnabled = isNumber
        repeatField.isEnabled = isNumber
    }

    // MARK: - View construction

    private func buildUI(in content: NSView?) {
        guard let content else { return }

        textRadio.frame = NSRect(x: 20, y: 214, width: 160, height: 18)
        numberRadio.frame = NSRect(x: 190, y: 214, width: 170, height: 18)
        content.addSubview(textRadio)
        content.addSubview(numberRadio)

        insertionField.frame = NSRect(x: 120, y: 176, width: 238, height: 22)
        insertionField.bezelStyle = .roundedBezel
        insertionField.font = .systemFont(ofSize: 13)
        content.addSubview(insertionField)
        content.addSubview(label("Text to insert:", at: 178))

        initialField.frame = NSRect(x: 120, y: 138, width: 238, height: 22)
        initialField.bezelStyle = .roundedBezel
        initialField.font = .systemFont(ofSize: 13)
        content.addSubview(initialField)
        content.addSubview(label("Initial number:", at: 140))

        stepField.frame = NSRect(x: 120, y: 106, width: 238, height: 22)
        stepField.bezelStyle = .roundedBezel
        stepField.font = .systemFont(ofSize: 13)
        content.addSubview(stepField)
        content.addSubview(label("Increase by:", at: 108))

        repeatField.frame = NSRect(x: 120, y: 74, width: 238, height: 22)
        repeatField.bezelStyle = .roundedBezel
        repeatField.font = .systemFont(ofSize: 13)
        content.addSubview(repeatField)
        content.addSubview(label("Repeat:", at: 76))

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 200, y: 20, width: 80, height: 28)
        cancel.bezelStyle = .rounded
        let ok = NSButton(title: "OK", target: self, action: #selector(confirm(_:)))
        ok.frame = NSRect(x: 288, y: 20, width: 70, height: 28)
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        content.addSubview(cancel)
        content.addSubview(ok)
    }

    private func label(_ title: String, at y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.frame = NSRect(x: 20, y: y, width: 94, height: 18)
        field.font = .systemFont(ofSize: 13)
        field.alignment = .right
        return field
    }
}
