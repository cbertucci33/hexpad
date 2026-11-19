import AppKit
import HexpadKit

/// Macro > Run a Macro Multiple Times… (M22a): the alert that collects the
/// repeat count and the "Run until end of file" choice before the
/// ``MainWindowController/runMacroMultipleTimes(count:untilEOF:)`` core runs.
///
/// This alert is the only untested seam of the feature; the count/EOF core
/// is exercised through MainWindowController.
final class MacroRepeatWindowController {

    /// Presents the dialog. OK runs the core with the parsed count and the
    /// checkbox state; Cancel leaves the last macro untouched.
    static func showRunMacroMultipleTimes(for controller: MainWindowController) {
        let alert = NSAlert()
        alert.messageText = "Run Macro Multiple Times"
        alert.informativeText = "Replay the last recorded macro."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        stackView.orientation = .vertical
        stackView.spacing = 10

        let countRow = NSStackView()
        countRow.spacing = 8
        let countLabel = NSTextField(labelWithString: "Repeat count:")
        let countField = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        countField.stringValue = "3"
        countField.placeholderString = "Count"
        countRow.addArrangedSubview(countLabel)
        countRow.addArrangedSubview(countField)

        let untilEOFCheckbox = NSButton(checkboxWithTitle: "Run until end of file",
                                        target: nil,
                                        action: nil)
        untilEOFCheckbox.state = .off

        stackView.addArrangedSubview(countRow)
        stackView.addArrangedSubview(untilEOFCheckbox)
        alert.accessoryView = stackView

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let count = Int(countField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        controller.runMacroMultipleTimes(count: count,
                                         untilEOF: untilEOFCheckbox.state == .on)
    }
}
