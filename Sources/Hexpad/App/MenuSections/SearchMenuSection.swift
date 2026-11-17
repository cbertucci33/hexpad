import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeSearchMenu() -> NSMenu {
        let searchMenu = NSMenu(title: "Search")
        let findInDocItem = NSMenuItem(title: "Find...", action: #selector(toggleFindBar), keyEquivalent: "f")
        findInDocItem.target = self
        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        findNextItem.target = self
        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(findPrevious), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        
        searchMenu.addItem(findInDocItem)
        searchMenu.addItem(findNextItem)
        searchMenu.addItem(findPrevItem)
        searchMenu.addItem(.separator())
        let findInFilesItem = NSMenuItem(title: "Find in Files...", action: #selector(findInFiles), keyEquivalent: "F")
        findInFilesItem.keyEquivalentModifierMask = [.command, .shift]
        findInFilesItem.target = self
        searchMenu.addItem(findInFilesItem)
        return searchMenu
    }
}
