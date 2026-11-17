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

        // N++ Select and Find / Find (Volatile). No chords: N++ assigns none,
        // and Cmd+F / Cmd+G / Shift+Cmd+G already cover the field-driven paths.
        // Nil-targeted like Find All so the focused window's controller can
        // read the editor selection. Validation stays enabled for all four;
        // the actions no-op when there is no selection and no word at caret.
        let selectFindNextItem = NSMenuItem(title: "Select and Find Next",
                                            action: #selector(MainWindowController.selectAndFindNext(_:)),
                                            keyEquivalent: "")
        selectFindNextItem.target = nil
        let selectFindPrevItem = NSMenuItem(title: "Select and Find Previous",
                                            action: #selector(MainWindowController.selectAndFindPrevious(_:)),
                                            keyEquivalent: "")
        selectFindPrevItem.target = nil
        let volatileNextItem = NSMenuItem(title: "Find (Volatile) Next",
                                          action: #selector(MainWindowController.findVolatileNext(_:)),
                                          keyEquivalent: "")
        volatileNextItem.target = nil
        let volatilePrevItem = NSMenuItem(title: "Find (Volatile) Previous",
                                          action: #selector(MainWindowController.findVolatilePrevious(_:)),
                                          keyEquivalent: "")
        volatilePrevItem.target = nil
        searchMenu.addItem(selectFindNextItem)
        searchMenu.addItem(selectFindPrevItem)
        searchMenu.addItem(volatileNextItem)
        searchMenu.addItem(volatilePrevItem)

        // N++ Incremental Search. Cmd+I is free across every menu section and
        // the editor command registry, so it gets the chord. Nil-targeted so
        // the focused window's controller owns the toggle and validation.
        let incrementalSearchItem = NSMenuItem(title: "Incremental Search",
                                               action: #selector(MainWindowController.toggleIncrementalSearch(_:)),
                                               keyEquivalent: "i")
        incrementalSearchItem.target = nil
        searchMenu.addItem(incrementalSearchItem)

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

        // N++ F4 / Shift+F4 walk the results window. Nil-targeted so the
        // focused window's controller handles them: the results window itself
        // while it is key, MainWindowController as a passthrough otherwise.
        // Bare function keys need an empty mask; the default is Command.
        let nextResultItem = NSMenuItem(title: "Next Result",
                                        action: #selector(MainWindowController.nextSearchResult(_:)),
                                        keyEquivalent: "\u{F707}")
        nextResultItem.keyEquivalentModifierMask = []
        nextResultItem.target = nil
        let previousResultItem = NSMenuItem(title: "Previous Result",
                                            action: #selector(MainWindowController.previousSearchResult(_:)),
                                            keyEquivalent: "\u{F707}")
        previousResultItem.keyEquivalentModifierMask = [.shift]
        previousResultItem.target = nil
        searchMenu.addItem(nextResultItem)
        searchMenu.addItem(previousResultItem)
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
