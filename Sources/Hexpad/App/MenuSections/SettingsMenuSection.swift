import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeAppMenu() -> NSMenu {
        let appSubMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        // Notepad++ Settings > Shortcut Mapper. Read-only in v1 (editing comes
        // in a later update). No chord: Cmd+, belongs to Preferences and no
        // other standard shortcut is free.
        let shortcutMapperItem = NSMenuItem(title: "Shortcut Mapper…",
                                            action: #selector(showShortcutMapper),
                                            keyEquivalent: "")
        shortcutMapperItem.target = self
        let hideItem = NSMenuItem(title: "Hide Hexpad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit Hexpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        appSubMenu.addItem(aboutItem)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(preferencesItem)
        appSubMenu.addItem(shortcutMapperItem)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(hideItem)
        appSubMenu.addItem(hideOthersItem)
        appSubMenu.addItem(showAllItem)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(quitItem)
        return appSubMenu
    }
}
