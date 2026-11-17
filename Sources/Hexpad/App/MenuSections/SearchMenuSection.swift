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

        // The Find dialog's "Find All" pair lives here as direct N++-style
        // items. Nil-targeted so the focused window's controller (which owns
        // the open documents) runs them and supplies validation.
        let findAllInDocItem = NSMenuItem(title: "Find All in Current Document",
                                          action: #selector(MainWindowController.findAllInCurrentDocument(_:)),
                                          keyEquivalent: "")
        findAllInDocItem.target = nil
        let findAllOpenedItem = NSMenuItem(title: "Find All in All Opened Documents",
                                           action: #selector(MainWindowController.findAllInAllOpenedDocuments(_:)),
                                           keyEquivalent: "")
        findAllOpenedItem.target = nil
        searchMenu.addItem(findAllInDocItem)
        searchMenu.addItem(findAllOpenedItem)
        searchMenu.addItem(.separator())
        let findInFilesItem = NSMenuItem(title: "Find in Files...", action: #selector(findInFiles), keyEquivalent: "F")
        findInFilesItem.keyEquivalentModifierMask = [.command, .shift]
        findInFilesItem.target = self
        searchMenu.addItem(findInFilesItem)
        searchMenu.addItem(.separator())

        // Search > Bookmark mirrors the registry's bookmark group. The group
        // already owns key chords through the Text menu, so these items carry
        // no duplicate equivalents; validation still runs through the
        // controller's bookmark action.
        let bookmarkMenu = NSMenu(title: "Bookmark")
        for command in CommandRegistry.default.bookmarkCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performBookmarkCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            bookmarkMenu.addItem(item)
            if command.identifier == "bookmark-clear-all" {
                bookmarkMenu.addItem(.separator())
            }
        }
        let bookmarkItem = NSMenuItem(title: "Bookmark", action: nil, keyEquivalent: "")
        bookmarkItem.submenu = bookmarkMenu
        searchMenu.addItem(bookmarkItem)
        return searchMenu
    }
}
