import AppKit

/// Default menu key equivalents for the editor commands in `CommandRegistry`.
///
/// Notepad++ is the parity target, but macOS owns several of its chords
/// (Ctrl+Shift+Up/Down extends the selection; Ctrl+U is not a menu chord on
/// Mac). These bindings keep the N++ intent while using chords the platform
/// already treats as line editing: Cmd+D for duplicate, Cmd+Shift+D for delete,
/// and the Xcode move-line pair for Cmd+Option+Up/Down.
struct EditorCommandBinding {

    let identifier: String
    let keyEquivalent: String
    let modifierMask: NSEvent.ModifierFlags

    /// Arrow key equivalents use AppKit's private-use function-key scalars.
    static let upArrow = "\u{F700}"
    static let downArrow = "\u{F701}"

    static let defaultBindings: [EditorCommandBinding] = [
        EditorCommandBinding(identifier: "duplicate-line",
                             keyEquivalent: "d",
                             modifierMask: [.command]),
        EditorCommandBinding(identifier: "delete-line",
                             keyEquivalent: "d",
                             modifierMask: [.command, .shift]),
        EditorCommandBinding(identifier: "move-line-up",
                             keyEquivalent: upArrow,
                             modifierMask: [.command, .option]),
        EditorCommandBinding(identifier: "move-line-down",
                             keyEquivalent: downArrow,
                             modifierMask: [.command, .option]),
        EditorCommandBinding(identifier: "toggle-line-comment",
                             keyEquivalent: "/",
                             modifierMask: [.command]),
        EditorCommandBinding(identifier: "uppercase",
                             keyEquivalent: "u",
                             modifierMask: [.command, .shift]),
        EditorCommandBinding(identifier: "lowercase",
                             keyEquivalent: "u",
                             modifierMask: [.command])
    ]

    static func binding(for identifier: String) -> EditorCommandBinding? {
        defaultBindings.first { $0.identifier == identifier }
    }
}
