import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: "Window")
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let zoomItem = NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let bringAllToFrontItem = NSMenuItem(title: "Bring All to Front",
                                             action: #selector(NSApplication.arrangeInFront(_:)),
                                             keyEquivalent: "")
        bringAllToFrontItem.target = NSApp
        let fullscreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreenItem.keyEquivalentModifierMask = [.command, .control]
        
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(zoomItem)
        windowMenu.addItem(bringAllToFrontItem)
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

        // W23a: sorting is a tab-order operation, so it sits with the other tab
        // commands. The submenu is shared with the tab context menu.
        windowMenu.addItem(.separator())
        windowMenu.addItem(TabSortMenu.makeItem())
        NSApp.windowsMenu = windowMenu
        return windowMenu
    }
}

/// Builds the one "Sort By" submenu presented by both Window > Sort By and the
/// tab context menu. One nil-targeted action covers all ten items: the key is
/// in representedObject and the tag distinguishes ascending (1) from
/// descending (0).
enum TabSortMenu {
    static func makeItem() -> NSMenuItem {
        let sortByItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortByMenu = NSMenu(title: "Sort By")
        let sortCommands: [(title: String, key: TabSortKey, ascending: Bool)] = [
            ("Name (Ascending)", .name, true),
            ("Name (Descending)", .name, false),
            ("Path (Ascending)", .path, true),
            ("Path (Descending)", .path, false),
            ("Type (Ascending)", .type, true),
            ("Type (Descending)", .type, false),
            ("Length (Ascending)", .length, true),
            ("Length (Descending)", .length, false),
            ("Modified (Ascending)", .modified, true),
            ("Modified (Descending)", .modified, false),
        ]
        for command in sortCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.sortDocumentsBy(_:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.key.rawValue
            item.tag = command.ascending ? 1 : 0
            sortByMenu.addItem(item)
        }
        sortByItem.submenu = sortByMenu
        return sortByItem
    }
}
