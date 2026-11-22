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

        toolsMenu.addItem(.separator())
        // V19g: per-document tail -f, the single monitoring surface. (The old
        // View > Monitoring watcher opt-out was removed: it contradicted this
        // toggle and could silently defeat it.) Checkmarked and nil-targeted so
        // MainWindowController owns both the state and the untitled-file
        // validation. Menu-only: no N++ macOS chord exists for this toggle.
        let monitorFileItem = NSMenuItem(title: "Monitor File",
                                         action: #selector(MainWindowController.toggleFileMonitoring(_:)),
                                         keyEquivalent: "")
        monitorFileItem.target = nil
        toolsMenu.addItem(monitorFileItem)

        // V19h: document statistics, the single home for the dialog (Pilot
        // P-08). The HIG ellipsis marks an item that opens a window; the
        // dialog's own title is "Document Summary".
        let documentSummaryItem = NSMenuItem(title: "Document Summary…",
                                             action: #selector(MainWindowController.showSummary(_:)),
                                             keyEquivalent: "")
        documentSummaryItem.target = nil
        toolsMenu.addItem(documentSummaryItem)
        return toolsMenu
    }
}
