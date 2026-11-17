import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeLineOpsMenu() -> NSMenu {
        // items share the same identifiers, macro capture and keybinding
        // override path as the Text menu.
        let lineOpsMenu = NSMenu(title: "Line Operations")
        for command in CommandRegistry.default.lineOpCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            lineOpsMenu.addItem(item)
        }
        return lineOpsMenu
    }
}
