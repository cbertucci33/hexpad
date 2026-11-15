import AppKit

/// Minimal "press any key combination" capture UI.
///
/// The Keybindings submenu is the editor: choosing an item opens this small
/// modal alert, which captures the next chord and returns it to the caller.
/// Nothing is persisted here; `HexpadAppDelegate` hands the result to
/// `KeybindingStore` and the menu rebuild listener takes care of the rest.
enum KeybindingCapture {

    struct Result {
        let keyEquivalent: String
        let modifierMask: NSEvent.ModifierFlags
    }

    private static let capturedResponse = NSApplication.ModalResponse(rawValue: 1001)
    private static let cancelledResponse = NSApplication.ModalResponse(rawValue: 1002)

    static func run(commandTitle: String,
                    current: EditorCommandBinding?) -> Result? {
        let alert = NSAlert()
        alert.messageText = "Shortcut for \(commandTitle)"
        alert.informativeText = "Press a key combination.\nEscape cancels."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel")

        let field = KeyCaptureField(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .center
        field.isBezeled = true
        field.isEditable = false
        field.isSelectable = false
        field.stringValue = current.map { KeybindingStore.displayString(for: $0) } ?? "Press keys…"

        var captured: Result?
        field.onChord = { keyEquivalent, modifierMask in
            captured = Result(keyEquivalent: keyEquivalent, modifierMask: modifierMask)
            NSApp.stopModal(withCode: capturedResponse)
        }
        field.onCancel = {
            NSApp.stopModal(withCode: cancelledResponse)
        }

        alert.accessoryView = field
        alert.window.makeFirstResponder(field)
        // The alert window can steal first responder while it orders front.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
        }

        let response = alert.runModal()
        alert.window.orderOut(nil)
        return response == capturedResponse ? captured : nil
    }
}

/// A read-only text field that reports the first Chord it receives. Using a
/// field instead of a custom view keeps the alert's default layout and focus
/// ring for free.
private final class KeyCaptureField: NSTextField {

    var onChord: ((String, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        if event.keyCode == 53 { // Escape
            onCancel?()
            return true
        }

        guard let chord = KeybindingStore.keyChord(from: event) else {
            // A modifier-less key would hijack typing if installed as a menu
            // equivalent, so reject it without closing the sheet.
            NSSound.beep()
            return true
        }

        onChord?(chord.keyEquivalent, chord.modifierMask)
        return true
    }
}
