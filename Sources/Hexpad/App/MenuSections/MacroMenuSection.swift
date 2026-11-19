import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeMacroMenu() -> NSMenu {
        // action is nil-targeted so MainWindowController (the owner of the
        // recorder state) handles both the action and its enabled state. The
        // two name-list submenus are rebuilt by this delegate on open, like
        // Open Recent, so they always mirror macros.json.
        let macroMenu = NSMenu(title: "Macro")
        let recordItem = NSMenuItem(title: "Record Macro",
                                    action: #selector(MainWindowController.toggleMacroRecording(_:)),
                                    keyEquivalent: "")
        recordItem.target = nil
        let stopRecordingItem = NSMenuItem(title: "Stop Recording",
                                           action: #selector(MainWindowController.stopRecordingMacro(_:)),
                                           keyEquivalent: "")
        stopRecordingItem.target = nil
        let playLastItem = NSMenuItem(title: "Play Last Macro",
                                      action: #selector(MainWindowController.playLastMacro(_:)),
                                      keyEquivalent: "")
        playLastItem.target = nil
        // M22a: N++'s repeat-count command. Nil-targeted like the other
        // macro actions; MainWindowController validates it against a recorded
        // macro and a focused document.
        let runMultipleItem = NSMenuItem(title: "Run a Macro Multiple Times…",
                                         action: #selector(MainWindowController.showRunMacroMultipleTimesDialog(_:)),
                                         keyEquivalent: "")
        runMultipleItem.target = nil

        let playMacroMenu = macroListMenu(title: "Play Macro",
                                          action: #selector(MainWindowController.playSavedMacro(_:)))
        let playMacroItem = NSMenuItem(title: "Play Macro", action: nil, keyEquivalent: "")
        playMacroItem.submenu = playMacroMenu
        playMacroMenu.delegate = self
        self.playMacroMenu = playMacroMenu

        let saveRecordingItem = NSMenuItem(title: "Save Recording As…",
                                           action: #selector(MainWindowController.saveRecordingAs(_:)),
                                           keyEquivalent: "")
        saveRecordingItem.target = nil

        let deleteMacroMenu = macroListMenu(title: "Delete Macro",
                                            action: #selector(MainWindowController.deleteMacro(_:)))
        let deleteMacroItem = NSMenuItem(title: "Delete Macro", action: nil, keyEquivalent: "")
        deleteMacroItem.submenu = deleteMacroMenu
        deleteMacroMenu.delegate = self
        self.deleteMacroMenu = deleteMacroMenu

        macroMenu.addItem(recordItem)
        macroMenu.addItem(stopRecordingItem)
        macroMenu.addItem(.separator())
        macroMenu.addItem(playLastItem)
        macroMenu.addItem(runMultipleItem)
        macroMenu.addItem(playMacroItem)
        macroMenu.addItem(.separator())
        macroMenu.addItem(saveRecordingItem)
        macroMenu.addItem(deleteMacroItem)
        return macroMenu
    }

    /// A Macro submenu that lists saved macros by name. Built from
    /// ``MacroStore`` so the same data drives the menu and playback; the
    /// controller validates each nil-targeted item through the responder chain.
    private func macroListMenu(title: String, action: Selector) -> NSMenu {
        let menu = NSMenu(title: title)
        populateMacroList(menu, action: action)
        return menu
    }

    /// Rebuilds `menu` from the current saved macros. A disabled
    /// "No Saved Macros" placeholder keeps the submenu well-formed when empty,
    /// matching the Open Recent convention.
    func populateMacroList(_ menu: NSMenu, action: Selector) {
        menu.removeAllItems()

        let macros = MacroStore.load()
        guard !macros.isEmpty else {
            let emptyItem = NSMenuItem(title: "No Saved Macros", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        let isPlay = action == #selector(MainWindowController.playSavedMacro(_:))
        for macro in macros {
            let item = NSMenuItem(title: macro.name, action: action, keyEquivalent: "")
            item.target = nil
            item.representedObject = macro.name
            // An empty macro can still be deleted, but there is nothing to play.
            if isPlay && macro.isEmpty {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
    }
}