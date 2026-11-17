import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeRunMenu() -> NSMenu {
        // rather than nesting it under Tools, so Hexpad mirrors that layout.
        // The item is nil-targeted so MainWindowController supplies both the
        // action and the no-document validation. A bare function key means an
        // empty modifier mask: the default would be Command.
        let runMenu = NSMenu(title: "Run")
        let runItem = NSMenuItem(title: "Run…",
                                 action: #selector(MainWindowController.showRunCommandDialog(_:)),
                                 keyEquivalent: "\u{F708}")
        runItem.keyEquivalentModifierMask = []
        runItem.target = nil
        runMenu.addItem(runItem)
        return runMenu
    }
}
