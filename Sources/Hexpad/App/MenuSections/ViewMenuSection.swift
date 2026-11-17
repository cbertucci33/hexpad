import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeViewMenu() -> NSMenu {
        let viewMenu = NSMenu(title: "View")
        let wordWrapItem = NSMenuItem(title: "Word Wrap", action: #selector(toggleWordWrap), keyEquivalent: "y")
        wordWrapItem.target = self
        // These three view actions are registry identifiers too, so a saved
        // keybinding override applies even though the items keep their stable
        // selectors (and Fold All/Unfold All keep nil targets for validation).
        wordWrapItem.representedObject = "toggle-word-wrap"
        if let binding = KeybindingStore.resolvedBinding(for: "toggle-word-wrap") {
            wordWrapItem.keyEquivalent = binding.keyEquivalent
            wordWrapItem.keyEquivalentModifierMask = binding.modifierMask
        }
        // Notepad++ toggles the Function List with Ctrl+F12; the macOS
        // convention is the same chord with Command. F12 alone is left to the
        // system (Mission Control/Launchpad on some setups). The item is
        // nil-targeted so MainWindowController validates it against the open
        // document and can check it while the panel is visible.
        let functionListItem = NSMenuItem(title: "Function List",
                                          action: #selector(MainWindowController.toggleFunctionList(_:)),
                                          keyEquivalent: "\u{F70F}")
        functionListItem.keyEquivalentModifierMask = [.command]
        functionListItem.target = nil
        // Notepad++ folding convention (Alt+0 / Alt+Shift+0) expressed with
        // Option. Both are nil-targeted so MainWindowController disables them
        // when the selected document has no foldable ranges.
        let foldAllItem = NSMenuItem(title: "Fold All",
                                     action: #selector(MainWindowController.foldAll(_:)),
                                     keyEquivalent: "0")
        foldAllItem.keyEquivalentModifierMask = [.option]
        foldAllItem.target = nil
        foldAllItem.representedObject = "fold-all"
        if let binding = KeybindingStore.resolvedBinding(for: "fold-all") {
            foldAllItem.keyEquivalent = binding.keyEquivalent
            foldAllItem.keyEquivalentModifierMask = binding.modifierMask
        }
        let unfoldAllItem = NSMenuItem(title: "Unfold All",
                                       action: #selector(MainWindowController.unfoldAll(_:)),
                                       keyEquivalent: "0")
        unfoldAllItem.keyEquivalentModifierMask = [.option, .shift]
        unfoldAllItem.target = nil
        unfoldAllItem.representedObject = "unfold-all"
        if let binding = KeybindingStore.resolvedBinding(for: "unfold-all") {
            unfoldAllItem.keyEquivalent = binding.keyEquivalent
            unfoldAllItem.keyEquivalentModifierMask = binding.modifierMask
        }
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        let resetZoomItem = NSMenuItem(title: "Reset Zoom", action: #selector(resetZoom), keyEquivalent: "0")
        resetZoomItem.target = self
        
        // Appearance submenu
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        let useSystemItem = NSMenuItem(title: "Use System", action: #selector(setAppearanceSystem), keyEquivalent: "")
        useSystemItem.target = self
        useSystemItem.tag = 0
        let lightItem = NSMenuItem(title: "Light", action: #selector(setAppearanceLight), keyEquivalent: "")
        lightItem.target = self
        lightItem.tag = 1
        let darkItem = NSMenuItem(title: "Dark", action: #selector(setAppearanceDark), keyEquivalent: "")
        darkItem.target = self
        darkItem.tag = 2
        appearanceMenu.addItem(useSystemItem)
        appearanceMenu.addItem(lightItem)
        appearanceMenu.addItem(darkItem)
        appearanceItem.submenu = appearanceMenu
        self.appearanceMenu = appearanceMenu
        updateAppearanceCheckmarks()
        
        viewMenu.addItem(wordWrapItem)
        // Off by default (Notepad++'s Document Map is opt-in). Routed like
        // Word Wrap; the checkmark comes from menu validation.
        let documentMapItem = NSMenuItem(title: "Document Map",
                                         action: #selector(toggleDocumentMap),
                                         keyEquivalent: "")
        documentMapItem.target = self
        viewMenu.addItem(documentMapItem)
        viewMenu.addItem(functionListItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(foldAllItem)
        viewMenu.addItem(unfoldAllItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(zoomInItem)
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(resetZoomItem)
        viewMenu.addItem(.separator())
        // Split view: group 2 starts empty and tabs are dragged into it. The
        // item is nil-targeted so MainWindowController owns both the action and
        // the open/closed checkmark.
        let splitViewItem = NSMenuItem(title: "Toggle Split View",
                                       action: #selector(MainWindowController.toggleSplitView(_:)),
                                       keyEquivalent: "2")
        splitViewItem.keyEquivalentModifierMask = [.command, .shift]
        splitViewItem.target = nil
        viewMenu.addItem(splitViewItem)
        // Both are nil-targeted too: validation disables them while the split
        // is closed (sync has nothing to pair, and there is no other view).
        let synchronizeScrollItem = NSMenuItem(title: "Synchronize Scrolling",
                                               action: #selector(MainWindowController.toggleSynchronizeScrolling(_:)),
                                               keyEquivalent: "")
        synchronizeScrollItem.target = nil
        viewMenu.addItem(synchronizeScrollItem)
        let moveToOtherViewItem = NSMenuItem(title: "Move to Other View",
                                             action: #selector(MainWindowController.moveToOtherView(_:)),
                                             keyEquivalent: "")
        moveToOtherViewItem.target = nil
        viewMenu.addItem(moveToOtherViewItem)
        // Notepad++-style document switcher. Ctrl+Tab is the native in-app
        // chord (Cmd+Tab belongs to the system app switcher).
        let documentSwitcherItem = NSMenuItem(title: "Document Switcher…",
                                              action: #selector(MainWindowController.showDocumentSwitcher(_:)),
                                              keyEquivalent: "\t")
        documentSwitcherItem.keyEquivalentModifierMask = [.control]
        documentSwitcherItem.target = nil
        viewMenu.addItem(documentSwitcherItem)
        // AppKit allows one chord per menu item, so Ctrl+Shift+Tab is a second,
        // hidden item with the same action. `allowsKeyEquivalentWhenHidden`
        // keeps it live without cluttering the menu.
        let documentSwitcherBackItem = NSMenuItem(title: "Document Switcher",
                                                  action: #selector(MainWindowController.showDocumentSwitcher(_:)),
                                                  keyEquivalent: "\t")
        documentSwitcherBackItem.keyEquivalentModifierMask = [.control, .shift]
        documentSwitcherBackItem.target = nil
        documentSwitcherBackItem.isHidden = true
        documentSwitcherBackItem.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(documentSwitcherBackItem)
        // View > View Current File In > Default Browser: hand the selected
        // document to the system browser via Launch Services. The section
        // parent is actionless; the Default Browser leaf owns the selector and
        // is nil-targeted so validation can disable it for untitled docs.
        let viewCurrentFileInItem = NSMenuItem(title: "View Current File In", action: nil, keyEquivalent: "")
        let viewCurrentFileInMenu = NSMenu(title: "View Current File In")
        let defaultBrowserItem = NSMenuItem(title: "Default Browser",
                                             action: #selector(HexpadAppDelegate.viewCurrentFileInBrowser(_:)),
                                             keyEquivalent: "")
        defaultBrowserItem.target = nil
        viewCurrentFileInMenu.addItem(defaultBrowserItem)
        viewCurrentFileInItem.submenu = viewCurrentFileInMenu
        viewMenu.addItem(viewCurrentFileInItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(appearanceItem)
        return viewMenu
    }
}
