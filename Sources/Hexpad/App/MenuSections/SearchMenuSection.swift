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

        // N++ Insert-key overwrite mode. No standard Mac chord; bind to the
        // Insert function key when the keyboard has one, otherwise it simply
        // has no chord. Nil-targeted so the focused window's controller owns
        // the toggle and validation.
        let toggleOverwriteItem = NSMenuItem(title: "Toggle Overwrite Mode",
                                            action: #selector(MainWindowController.toggleOverwriteMode(_:)),
                                            keyEquivalent: "\u{F727}")
        toggleOverwriteItem.keyEquivalentModifierMask = []
        toggleOverwriteItem.target = nil
        searchMenu.addItem(toggleOverwriteItem)

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

        // Search > Go to Matching Brace / Select All In-between navigate by the
        // bracket pair at the caret. Nil-targeted like the other editor-driven
        // Search items so the focused window's controller reads the caret and
        // owns validation. No key equivalents: these commands have no default
        // chords, and KEYBINDINGS.md forbids inventing Windows-style ones.
        let goToMatchingBraceItem = NSMenuItem(
            title: "Go to Matching Brace",
            action: #selector(MainWindowController.goToMatchingBrace(_:)),
            keyEquivalent: ""
        )
        goToMatchingBraceItem.target = nil
        let selectAllInBetweenItem = NSMenuItem(
            title: "Select All In-between",
            action: #selector(MainWindowController.selectAllInBetweenBraces(_:)),
            keyEquivalent: ""
        )
        selectAllInBetweenItem.target = nil
        searchMenu.addItem(goToMatchingBraceItem)
        searchMenu.addItem(selectAllInBetweenItem)
        searchMenu.addItem(.separator())

        // Search > Style All Occurrences of Token / Style One Token / Clear
        // Style / Jump Up / Jump Down / Copy Styled Text mirror Notepad++'s
        // five-style workflow. Every item is nil-targeted so the focused
        // window's controller supplies the selection and validation, and the
        // registry identifier rides in representedObject like the bookmark
        // group.
        let registry = CommandRegistry.default
        func tokenStyleTitle(_ identifier: String) -> String {
            registry.command(for: identifier)?.title ?? identifier
        }
        func addTokenStyleSubmenu(title: String,
                                  identifiers: [String],
                                  trailingIdentifier: String? = nil,
                                  trailingTitle: String? = nil) {
            let submenu = NSMenu(title: title)
            func addItem(identifier: String, title: String) {
                let item = NSMenuItem(
                    title: title,
                    action: #selector(MainWindowController.performTokenStyleCommand(withIdentifier:)),
                    keyEquivalent: ""
                )
                item.target = nil
                item.representedObject = identifier
                submenu.addItem(item)
            }
            for identifier in identifiers {
                addItem(identifier: identifier, title: tokenStyleTitle(identifier))
            }
            if let trailingIdentifier {
                submenu.addItem(.separator())
                addItem(identifier: trailingIdentifier,
                        title: trailingTitle ?? tokenStyleTitle(trailingIdentifier))
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            searchMenu.addItem(parent)
        }
        let styleNumbers = Array(TokenStyleState.styleNumbers)
        addTokenStyleSubmenu(
            title: "Style All Occurrences of Token",
            identifiers: styleNumbers.map { "style-all-occurrences-\($0)" }
        )
        addTokenStyleSubmenu(
            title: "Style One Token",
            identifiers: styleNumbers.map { "style-one-token-\($0)" }
        )
        addTokenStyleSubmenu(
            title: "Clear Style",
            identifiers: styleNumbers.map { "clear-style-\($0)" },
            trailingIdentifier: "clear-style-all"
        )
        addTokenStyleSubmenu(
            title: "Jump Up",
            identifiers: styleNumbers.map { "jump-up-\($0)" }
        )
        addTokenStyleSubmenu(
            title: "Jump Down",
            identifiers: styleNumbers.map { "jump-down-\($0)" }
        )
        addTokenStyleSubmenu(
            title: "Copy Styled Text",
            identifiers: styleNumbers.map { "copy-styled-text-\($0)" },
            trailingIdentifier: "copy-styled-text-all"
        )

        // N++ Search > Multi-select group, next to the token-style commands.
        // Each leaf is a nil-targeted item carrying its registry identifier, so
        // the focused window's controller owns both the action and validation.
        // "Multi-select Next" is one item whose submenu holds the three pinned
        // match-mode variants. It is added after the token-style submenus so
        // their position in the Search menu stays stable.
        func multiSelectItem(_ identifier: String) -> NSMenuItem {
            let item = NSMenuItem(
                title: registry.command(for: identifier)?.title ?? identifier,
                action: #selector(MainWindowController.performMultiSelectCommand(withIdentifier:)),
                keyEquivalent: ""
            )
            item.target = nil
            item.representedObject = identifier
            return item
        }
        searchMenu.addItem(.separator())
        searchMenu.addItem(multiSelectItem("select-all-occurrences"))
        let nextModes = NSMenu(title: "Multi-select Next")
        for identifier in ["multi-select-next-ignore-case",
                           "multi-select-next-match-case",
                           "multi-select-next-whole-word"] {
            nextModes.addItem(multiSelectItem(identifier))
        }
        let multiSelectNextItem = NSMenuItem(title: "Multi-select Next", action: nil, keyEquivalent: "")
        multiSelectNextItem.submenu = nextModes
        searchMenu.addItem(multiSelectNextItem)
        searchMenu.addItem(multiSelectItem("multi-select-undo-latest"))
        searchMenu.addItem(multiSelectItem("multi-select-skip-current"))

        // P17g-2: Begin/End Select and its Column Mode variant follow the
        // Multi-select group. Both are nil-targeted and take their titles from
        // the registry, but use dedicated first-responder actions instead of a
        // String `representedObject`: the P17g-1 menu-shape test collects the
        // latter across the whole Search menu and pins it to that group alone.
        // Neither item disables for a missing anchor — the End half no-ops
        // (N++ parity) — and there is no default chord to invent here.
        searchMenu.addItem(.separator())
        let beginEndSelectItem = NSMenuItem(
            title: registry.command(for: "begin-end-select")?.title ?? "Begin/End Select",
            action: #selector(MainWindowController.beginEndSelect(_:)),
            keyEquivalent: ""
        )
        beginEndSelectItem.target = nil
        let beginEndSelectColumnItem = NSMenuItem(
            title: registry.command(for: "begin-end-select-column")?.title
                ?? "Begin/End Select in Column Mode",
            action: #selector(MainWindowController.beginEndSelectColumn(_:)),
            keyEquivalent: ""
        )
        beginEndSelectColumnItem.target = nil
        searchMenu.addItem(beginEndSelectItem)
        searchMenu.addItem(beginEndSelectColumnItem)

        // P17g-3: the Column Editor follows the column-mode item. Like its
        // neighbours it is nil-targeted, so the focused controller owns both
        // the panel and validation. Unlike them it needs an actual column
        // selection (more than one row caret) and has no invented key chord.
        searchMenu.addItem(.separator())
        let columnEditorItem = NSMenuItem(title: "Column Editor…",
                                          action: #selector(MainWindowController.showColumnEditor(_:)),
                                          keyEquivalent: "")
        columnEditorItem.target = nil
        searchMenu.addItem(columnEditorItem)

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
