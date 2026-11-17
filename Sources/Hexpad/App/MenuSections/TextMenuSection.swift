import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeTextMenu() -> NSMenu {
        // the identifiers used by the first-responder action. Separators group
        // line edits, moves, comments, and case changes like Notepad++.
        let textMenu = NSMenu(title: "Text")
        let textMenuSeparatorsAfter: Set<String> = ["delete-line", "move-line-down", "toggle-line-comment"]
        for command in CommandRegistry.default.commands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            textMenu.addItem(item)
            if textMenuSeparatorsAfter.contains(command.identifier) {
                textMenu.addItem(.separator())
            }
        }
        textMenu.addItem(.separator())
        // Bookmark commands share the registry and the controller's
        // DocumentState path, but use their own selector so the line-editing
        // group stays a contiguous, iterable block (and so menu validation can
        // distinguish the two groups). Chords follow Notepad++: Cmd+F2 toggle,
        // F2 next, Shift+F2 previous.
        for command in CommandRegistry.default.bookmarkCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performBookmarkCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            textMenu.addItem(item)
        }
        textMenu.addItem(.separator())
        textMenu.addItem(keybindingsMenuItem())
        return textMenu
    }

    /// The Keybindings submenu is also the editor: each command row records a
    /// new chord on click (Option-click works too), and Reset restores every
    /// built-in binding.
    private func keybindingsMenuItem() -> NSMenuItem {
        let keybindingsMenu = NSMenu(title: "Keybindings")

        let hintItem = NSMenuItem(title: "Click a command, then press a new shortcut",
                                  action: nil,
                                  keyEquivalent: "")
        hintItem.isEnabled = false
        keybindingsMenu.addItem(hintItem)
        keybindingsMenu.addItem(.separator())

        for command in CommandRegistry.default.commands {
            let binding = KeybindingStore.resolvedBinding(for: command.identifier)
            let title = "\(command.title)    \(KeybindingStore.displayString(for: binding))"
            let item = NSMenuItem(title: title,
                                  action: #selector(editKeybinding(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command.identifier
            keybindingsMenu.addItem(item)
        }

        keybindingsMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset to Defaults",
                                   action: #selector(resetKeybindings),
                                   keyEquivalent: "")
        resetItem.target = self
        keybindingsMenu.addItem(resetItem)

        let keybindingsItem = NSMenuItem(title: "Keybindings", action: nil, keyEquivalent: "")
        keybindingsItem.submenu = keybindingsMenu
        return keybindingsItem
    }
}
