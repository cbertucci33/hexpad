import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeHelpMenu() -> NSMenu {
        let helpMenu = NSMenu(title: "Help")
        let aboutHexpad = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        helpMenu.addItem(aboutHexpad)
        return helpMenu
    }
}
