import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: "Window")
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let zoomItem = NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullscreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreenItem.keyEquivalentModifierMask = [.command, .control]
        
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(zoomItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(fullscreenItem)

        // Tab navigation lives in the Window menu (Safari's convention). The
        // actions are nil-targeted so the controller participates in the first
        // responder chain and can validate them against the current tab count.
        windowMenu.addItem(.separator())
        let nextTabItem = NSMenuItem(title: "Next Tab",
                                     action: #selector(MainWindowController.selectNextTab(_:)),
                                     keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = nil
        let previousTabItem = NSMenuItem(title: "Previous Tab",
                                         action: #selector(MainWindowController.selectPreviousTab(_:)),
                                         keyEquivalent: "[")
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = nil
        windowMenu.addItem(nextTabItem)
        windowMenu.addItem(previousTabItem)
        windowMenu.addItem(.separator())
        for number in 1...9 {
            let item = NSMenuItem(title: "Tab \(number)",
                                  action: #selector(MainWindowController.selectTabByNumber(_:)),
                                  keyEquivalent: "\(number)")
            item.tag = number
            item.target = nil
            windowMenu.addItem(item)
        }
        return windowMenu
    }
}
