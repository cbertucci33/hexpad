import AppKit
import HexpadKit

/// Wave 6, docs review item 27: Search > Find Characters in Range… dialog.
/// Field takes "20-300" or a single number; OK selects every character whose
/// code point falls in the range (multi-caret via the editor's standard
/// state), reports the count, and closes. Pure validation/seams live in
/// `CharactersInRange` (Kit).
final class FindCharactersInRangeWindowController: NSWindowController {

    private let rangeField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "e.g. 20-300")
    var onApply: (([NSRange]) -> Void)?
    /// Test seam + decoupling: where the dialog reads the buffer. Defaults to
    /// the focused editor via the app singleton; tests inject text directly.
    var textProvider: (() -> String)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Find Characters in Range"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    /// Self-sufficient designated init: handed nil, builds the configured
    /// window (same pattern as ShortcutMapper/CharacterPanel).
    override init(window: NSWindow?) {
        if let window {
            super.init(window: window)
        } else {
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                     styleMask: [.titled, .closable],
                                     backing: .buffered, defer: false)
            newWindow.title = "Find Characters in Range"
            newWindow.isReleasedWhenClosed = false
            super.init(window: newWindow)
            buildUI()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let prompt = NSTextField(labelWithString: "Character range (e.g. 20-300):")
        prompt.frame = NSRect(x: 20, y: 80, width: 320, height: 16)
        content.addSubview(prompt)

        rangeField.frame = NSRect(x: 20, y: 48, width: 200, height: 24)
        rangeField.target = self
        rangeField.action = #selector(okClicked(_:))
        content.addSubview(rangeField)

        let okButton = NSButton(title: "OK", target: self, action: #selector(okClicked(_:)))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.frame = NSRect(x: 240, y: 44, width: 90, height: 28)
        content.addSubview(okButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 140, y: 44, width: 90, height: 28)
        content.addSubview(cancelButton)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 16, width: 320, height: 16)
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)
    }

    @objc private func okClicked(_ sender: Any?) {
        _ = confirm(input: rangeField.stringValue)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        window?.orderOut(nil)
    }

    /// Test seam: the exact OK path without AppKit. Returns the validation
    /// outcome; on success also fires `onApply` with the match ranges.
    @discardableResult
    func confirm(input: String) -> CharactersInRange.ParseError? {
        switch CharactersInRange.parse(input) {
        case .failure(let error):
            switch error {
            case .malformed: statusLabel.stringValue = "Enter a number or a range like 20-300."
            case .inverted: statusLabel.stringValue = "Low bound must be ≤ high bound."
            case .outOfRange: statusLabel.stringValue = "Range must end at or below 1114111 (0x10FFFF)."
            }
            return error
        case .success(let range):
            statusLabel.stringValue = ""
            window?.orderOut(nil)
            onApply?(CharactersInRange.matches(in: textProvider?() ?? activeText(), range: range))
            return nil
        }
    }

    private func activeText() -> String {
        NSApp.mainWindow?.contentViewController is MainWindowController
            ? (NSApp.mainWindow?.contentViewController as? MainWindowController)?.editorTextView?.string ?? ""
            : ""
    }
}
