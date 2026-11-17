import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeToolsMenu() -> NSMenu {
        // commands, so the items use the shared performCommand action and the
        // full identifier/keybinding/macro path. They stay nil-targeted so the
        // controller owns the no-document validation.
        let toolsMenu = NSMenu(title: "Tools")
        let toolCommands = CommandRegistry.default.toolCommands
        for command in toolCommands where command.identifier.hasPrefix("hash-") {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            toolsMenu.addItem(item)
        }
        toolsMenu.addItem(.separator())

        let dateTimeMenu = NSMenu(title: "Insert Date/Time")
        for command in toolCommands where command.identifier.hasPrefix("insert-") {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            dateTimeMenu.addItem(item)
        }
        let dateTimeItem = NSMenuItem(title: "Insert Date/Time", action: nil, keyEquivalent: "")
        dateTimeItem.submenu = dateTimeMenu
        toolsMenu.addItem(dateTimeItem)
        return toolsMenu
    }
}
