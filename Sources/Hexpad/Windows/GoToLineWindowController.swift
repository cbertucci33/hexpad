import AppKit
import HexpadKit

/// The outcome of validating the Go to Line field. Kept as a pure value so
/// tests can cover empty / invalid / out-of-range / valid without a panel.
enum GoToLineValidation: Equatable {
    /// A 1-based line inside the document.
    case valid(line: Int)
    /// The field was empty (or only whitespace).
    case empty
    /// The field was not an integer at all.
    case invalid
    /// A well-formed line number outside `1...lineCount`.
    case outOfRange(requested: Int, lineCount: Int)
}

/// Search > Go to... (N++ Ctrl+G). A small line-number dialog that moves the
/// caret to the start of the requested line and scrolls it into view.
///
/// The panel only collects the number; the jump itself is performed by the
/// owning `HexpadAppDelegate` through `onGoToLine`, so the dialog stays
/// reusable across documents and windows. All line math lives in the static
/// helpers, which are the tested seam.
final class GoToLineWindowController: NSWindowController {

    private let lineField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// Set by the owner; receives the validated 1-based line number.
    var onGoToLine: ((Int) -> Void)?

    /// Number of logical lines in the document the dialog was last shown for.
    private var lineCount = 1

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 170),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Go to Line"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let fieldLabel = NSTextField(labelWithString: "Line number:")
        fieldLabel.font = NSFont.systemFont(ofSize: 12)
        fieldLabel.frame = NSRect(x: 20, y: 112, width: 92, height: 20)
        content.addSubview(fieldLabel)

        lineField.placeholderString = "Line"
        lineField.frame = NSRect(x: 118, y: 110, width: 120, height: 24)
        lineField.target = self
        lineField.action = #selector(confirmClicked(_:))
        content.addSubview(lineField)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 82, width: 360, height: 16)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 190, y: 20, width: 90, height: 28)
        content.addSubview(cancelButton)

        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.target = self
        okButton.action = #selector(confirmClicked(_:))
        okButton.frame = NSRect(x: 288, y: 20, width: 92, height: 28)
        content.addSubview(okButton)
    }

    // MARK: - Testable line math

    /// Validates a raw field value against a document's line count.
    static func validate(lineInput: String, lineCount: Int) -> GoToLineValidation {
        let trimmed = lineInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let line = Int(trimmed) else { return .invalid }
        let upperBound = max(lineCount, 1)
        guard line >= 1, line <= upperBound else {
            return .outOfRange(requested: line, lineCount: lineCount)
        }
        return .valid(line: line)
    }

    /// Zero-length range at the start of 1-based `line`, clamped into `text`.
    /// Uses the shared `LineIndex` conventions (LF-only lines, UTF-16 offsets),
    /// so the caret lands exactly where the gutter and status bar say it will.
    static func lineStartRange(forLine line: Int, in text: String) -> NSRange {
        let index = LineIndex(text)
        let clamped = min(max(line, 1), max(index.count, 1))
        return NSRange(location: index.firstCharIndex(of: clamped), length: 0)
    }

    /// 1-based line and UTF-16 column for a location in `text`. Out-of-range
    /// locations clamp to the buffer, matching `LineIndex`'s caret conventions.
    static func lineColumn(at location: Int, in text: String) -> (line: Int, column: Int) {
        let index = LineIndex(text)
        let clamped = min(max(location, 0), index.textLength)
        let line = index.line(of: clamped)
        return (line, clamped - index.firstCharIndex(of: line) + 1)
    }

    /// The dialog's status line: the caret's current position and the total
    /// number of lines, e.g. "Line 3, Column 5 · 42 lines".
    static func positionSummary(at location: Int, in text: String, lineCount: Int) -> String {
        let position = lineColumn(at: location, in: text)
        return "Line \(position.line), Column \(position.column) · \(lineCount) lines"
    }

    // MARK: - Presentation

    /// Shows the dialog for `document`, reporting the caret's current line and
    /// column. The field starts empty so OK on an untouched dialog is a
    /// validated no-op rather than a jump to an arbitrary line.
    func show(for document: DocumentModel, at location: Int) {
        let index = LineIndex(document.text)
        lineCount = index.count
        statusLabel.stringValue = GoToLineWindowController.positionSummary(
            at: location, in: document.text, lineCount: lineCount)
        lineField.stringValue = ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Status line text currently shown in the dialog. Used by app tests.
    var positionText: String { statusLabel.stringValue }

    /// The validation the OK button would apply to the field's current value.
    func validateCurrentInput() -> GoToLineValidation {
        GoToLineWindowController.validate(lineInput: lineField.stringValue, lineCount: lineCount)
    }

    /// Test seam: feeds `input` through the exact OK path (validation, error
    /// text, `onGoToLine`) without clicking AppKit. Returns the result.
    @discardableResult
    func confirm(input: String) -> GoToLineValidation {
        lineField.stringValue = input
        return performConfirm()
    }

    @objc func confirmClicked(_ sender: Any?) {
        _ = performConfirm()
    }

    @objc private func cancel() {
        window?.orderOut(nil)
    }

    @discardableResult
    private func performConfirm() -> GoToLineValidation {
        let result = validateCurrentInput()
        switch result {
        case .valid(let line):
            onGoToLine?(line)
            window?.orderOut(nil)
        case .empty:
            statusLabel.stringValue = "Enter a line number."
        case .invalid:
            statusLabel.stringValue = "That is not a valid line number."
        case .outOfRange(let requested, let count):
            statusLabel.stringValue = "Line \(requested) is out of range (1–\(count))."
        }
        return result
    }
}
