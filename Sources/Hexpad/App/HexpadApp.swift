import AppKit
import HexpadKit

@main
class HexpadAppDelegate: NSObject, NSApplicationDelegate {
    
    // No MainMenu.nib exists, so the @main synthesis would never connect a delegate.
    // Bootstrap manually: create the app, attach the delegate, run.
    static func main() {
        let app = NSApplication.shared
        let delegate = HexpadAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
    
    private var mainWindow: MainWindow?
    private var windowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private let recentFilesManager = RecentFilesManager()
    private var openRecentMenu: NSMenu?
    private var appearanceMenu: NSMenu?
    private var playMacroMenu: NSMenu?
    private var deleteMacroMenu: NSMenu?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreAppearance()
        // Keybinding edits rebuild the whole menu: one code path applies the
        // overrides, and the rebuilt Keybindings submenu shows the new chords.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keybindingsDidChange(_:)),
                                               name: .keybindingsDidChange,
                                               object: nil)
        NSApplication.shared.mainMenu = buildMainMenu()
        
        let window = MainWindow()
        mainWindow = window
        
        let controller = MainWindowController(window: window)
        windowController = controller
        
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        
        controller.recentFilesManager = recentFilesManager
        restoreSession()
        // Persisted font/wrap/theme preferences are the startup defaults. The
        // restore path binds a tab and would otherwise leave a fresh install on
        // the built-in defaults until the first tab switch.
        controller.applyPreferences()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Dirty documents stay dirty on quit; the session store preserves dirty buffers.
        // saveSession writes immediately (superseding the debounced write), so
        // the quit path never waits for a pending timer.
        if let wc = windowController {
            // Then save the session state
            wc.saveSession()
        }
        return .terminateNow
    }
    
    // MARK: - Session
    
    private func restoreSession() {
        guard let (tabs, index) = SessionStore.restore() else { return }
        
        // Keep untitled buffers and file-backed tabs whose file still exists.
        // A missing file is only dropped when there is nothing to lose; see
        // `restorableDocuments(from:)`.
        let validDocs = Self.restorableDocuments(from: tabs.documents)
        
        // Restore tab store with filtered documents
        let restoredTabs = TabStore()
        for doc in validDocs {
            restoredTabs.addDocument(doc)
        }
        
        // Restore selected index (clamp to valid range)
        let restoredIndex = min(index, max(0, restoredTabs.count - 1))
        restoredTabs.selectedIndex = restoredIndex
        
        windowController?.tabStore.documents = restoredTabs.documents
        windowController?.tabStore.selectedIndex = restoredIndex
        windowController?.refreshTabBar()
        windowController?.updateEditor()
    }

    /// Chooses which documents from a saved session are worth restoring.
    ///
    /// Untitled buffers and file-backed tabs whose file still exists always
    /// survive. A tab whose file has disappeared survives only while it has
    /// unsaved changes: dropping it silently discarded the buffer, so the
    /// buffer is kept as an ordinary dirty tab. Its `filePath` is preserved,
    /// which means Save writes back to the original location (re-creating the
    /// file) instead of asking for a new name; Save As still offers that.
    static func restorableDocuments(from documents: [DocumentModel]) -> [DocumentModel] {
        documents.filter { doc in
            guard let path = doc.filePath?.path else { return true }
            if FileManager.default.fileExists(atPath: path) { return true }
            return doc.unsavedChanges
        }
    }
    
    // MARK: - Menu
    
    func buildMainMenu() -> NSMenu {
        let menu = NSMenu()
        
        // App menu
        let appItem = NSMenuItem()
        let appSubMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        let hideItem = NSMenuItem(title: "Hide Hexpad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit Hexpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        appSubMenu.addItem(aboutItem)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(preferencesItem)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(hideItem)
        appSubMenu.addItem(hideOthersItem)
        appSubMenu.addItem(showAllItem)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(quitItem)
        appItem.submenu = appSubMenu
        menu.addItem(appItem)
        
        // File menu
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        newWindowItem.target = self
        let newItem = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        newItem.target = self
        let openItem = NSMenuItem(title: "Open...", action: #selector(openFile), keyEquivalent: "o")
        openItem.target = self
        let saveItem = NSMenuItem(title: "Save", action: #selector(saveFile), keyEquivalent: "s")
        saveItem.target = self
        let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(saveAsFile), keyEquivalent: "S")
        saveAsItem.target = self
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        closeTabItem.target = self
        let closeAllItem = NSMenuItem(title: "Close All Tabs", action: #selector(closeAllTabs), keyEquivalent: "W")
        closeAllItem.target = self
        
        // Open Recent submenu
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        self.openRecentMenu = openRecentMenu
        
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(newItem)
        fileMenu.addItem(openItem)
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(saveItem)
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeTabItem)
        fileMenu.addItem(closeAllItem)
        menu.addItem((NSMenuItem(title: "File", action: nil, keyEquivalent: "").apply { $0.submenu = fileMenu }))
        
        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let findItem = NSMenuItem(title: "Find...", action: #selector(toggleFindBar), keyEquivalent: "f")
        findItem.target = self
        
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        editMenu.addItem(findItem)
        menu.addItem((NSMenuItem(title: "Edit", action: nil, keyEquivalent: "").apply { $0.submenu = editMenu }))

        // Text menu: the Kit-owned command registry drives both the items and
        // the identifiers used by the first-responder action. Separators group
        // line edits, moves, comments, and case changes like Notepad++.
        let textMenu = NSMenu(title: "Text")
        let textMenuSeparatorsAfter: Set<String> = ["delete-line", "move-line-down", "toggle-line-comment"]
        for command in CommandRegistry.default.commands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            textMenu.addItem(item)
            if textMenuSeparatorsAfter.contains(command.identifier) {
                textMenu.addItem(.separator())
            }
        }
        textMenu.addItem(.separator())
        // Bookmark commands share the registry and the controller's
        // DocumentState path, but use their own selector so the line-editing
        // group stays a contiguous, iterable block (and so menu validation can
        // distinguish the two groups). Chords follow Notepad++: Cmd+F2 toggle,
        // F2 next, Shift+F2 previous.
        for command in CommandRegistry.default.bookmarkCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performBookmarkCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            textMenu.addItem(item)
        }
        textMenu.addItem(.separator())
        textMenu.addItem(keybindingsMenuItem())
        menu.addItem((NSMenuItem(title: "Text", action: nil, keyEquivalent: "").apply { $0.submenu = textMenu }))
        
        // Search menu
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
        menu.addItem((NSMenuItem(title: "Search", action: nil, keyEquivalent: "").apply { $0.submenu = searchMenu }))

        // View menu
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
        viewMenu.addItem(.separator())
        viewMenu.addItem(appearanceItem)
        menu.addItem((NSMenuItem(title: "View", action: nil, keyEquivalent: "").apply { $0.submenu = viewMenu }))
        
        // Encoding menu: Notepad++ separates "Encode in" (reinterpret the raw
        // bytes, no transcoding) from "Convert to" (retarget the bytes the next
        // save writes). Items are nil-targeted so MainWindowController's
        // validation supplies enabled state and the current-encoding checkmarks.
        let encodingMenu = NSMenu(title: "Encoding")
        let encodingSections: [(title: String, action: Selector)] = [
            ("Encode in", #selector(MainWindowController.encodeIn(_:))),
            ("Convert to", #selector(MainWindowController.convertToEncoding(_:)))
        ]
        for section in encodingSections {
            let submenu = NSMenu(title: section.title)
            for option in MainWindowController.encodingOptions {
                let item = NSMenuItem(title: option.title, action: section.action, keyEquivalent: "")
                item.target = nil
                item.representedObject = option.name
                submenu.addItem(item)
            }
            let sectionItem = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            sectionItem.submenu = submenu
            encodingMenu.addItem(sectionItem)
        }

        // EOL submenu lived in the model (convertEOL) but had no UI at all.
        encodingMenu.addItem(.separator())
        let eolMenu = NSMenu(title: "Line Endings")
        for (title, sel) in [("LF (Unix)", #selector(setEOLLF)),
                             ("CRLF (Windows)", #selector(setEOLCRLF)),
                             ("CR (Classic Mac)", #selector(setEOLCR))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            eolMenu.addItem(item)
        }
        let eolItem = NSMenuItem(title: "Line Endings", action: nil, keyEquivalent: "")
        eolItem.submenu = eolMenu
        encodingMenu.addItem(eolItem)
        menu.addItem((NSMenuItem(title: "Encoding", action: nil, keyEquivalent: "").apply { $0.submenu = encodingMenu }))

        // Line operations menu: the registry owns these commands, so the menu
        // items share the same identifiers, macro capture and keybinding
        // override path as the Text menu.
        let lineOpsMenu = NSMenu(title: "Line Operations")
        for command in CommandRegistry.default.lineOpCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            lineOpsMenu.addItem(item)
        }
        menu.addItem((NSMenuItem(title: "Line Ops", action: nil, keyEquivalent: "").apply { $0.submenu = lineOpsMenu }))
        
        // Language menu
        let languageMenu = NSMenu(title: "Language")
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.rawValue, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Language.allCases.firstIndex(of: lang) ?? 0
            languageMenu.addItem(item)
        }
        menu.addItem((NSMenuItem(title: "Language", action: nil, keyEquivalent: "").apply { $0.submenu = languageMenu }))

        // Macro menu: recording, replay, and saved-macro management. Every
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
        macroMenu.addItem(playMacroItem)
        macroMenu.addItem(.separator())
        macroMenu.addItem(saveRecordingItem)
        macroMenu.addItem(deleteMacroItem)
        menu.addItem((NSMenuItem(title: "Macro", action: nil, keyEquivalent: "").apply { $0.submenu = macroMenu }))

        // Run menu: Notepad++ gives Run… its own top-level Run menu with F5,
        // rather than nesting it under Tools, so Hexpad mirrors that layout.
        // The item is nil-targeted so MainWindowController supplies both the
        // action and the no-document validation. A bare function key means an
        // empty modifier mask: the default would be Command.
        let runMenu = NSMenu(title: "Run")
        let runItem = NSMenuItem(title: "Run…",
                                 action: #selector(MainWindowController.showRunCommandDialog(_:)),
                                 keyEquivalent: "\u{F708}")
        runItem.keyEquivalentModifierMask = []
        runItem.target = nil
        runMenu.addItem(runItem)
        menu.addItem((NSMenuItem(title: "Run", action: nil, keyEquivalent: "").apply { $0.submenu = runMenu }))

        // Tools menu: hashing and date/time insertion. Both groups are registry
        // commands, so the items use the shared performCommand action and the
        // full identifier/keybinding/macro path. They stay nil-targeted so the
        // controller owns the no-document validation.
        let toolsMenu = NSMenu(title: "Tools")
        let toolCommands = CommandRegistry.default.toolCommands
        for command in toolCommands where command.identifier.hasPrefix("hash-") {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            toolsMenu.addItem(item)
        }
        toolsMenu.addItem(.separator())

        let dateTimeMenu = NSMenu(title: "Insert Date/Time")
        for command in toolCommands where command.identifier.hasPrefix("insert-") {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            if let binding = KeybindingStore.resolvedBinding(for: command.identifier) {
                item.keyEquivalent = binding.keyEquivalent
                item.keyEquivalentModifierMask = binding.modifierMask
            }
            dateTimeMenu.addItem(item)
        }
        let dateTimeItem = NSMenuItem(title: "Insert Date/Time", action: nil, keyEquivalent: "")
        dateTimeItem.submenu = dateTimeMenu
        toolsMenu.addItem(dateTimeItem)
        menu.addItem((NSMenuItem(title: "Tools", action: nil, keyEquivalent: "").apply { $0.submenu = toolsMenu }))
        
        // Window menu
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
        menu.addItem((NSMenuItem(title: "Window", action: nil, keyEquivalent: "").apply { $0.submenu = windowMenu }))
        
        // Help menu
        let helpMenu = NSMenu(title: "Help")
        let aboutHexpad = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        helpMenu.addItem(aboutHexpad)
        menu.addItem((NSMenuItem(title: "Help", action: nil, keyEquivalent: "").apply { $0.submenu = helpMenu }))
        
        NSApplication.shared.menu = menu
        return menu
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
    private func populateMacroList(_ menu: NSMenu, action: Selector) {
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

    /// The Keybindings submenu is also the editor: each command row records a
    /// new chord on click (Option-click works too), and Reset restores every
    /// built-in binding.
    private func keybindingsMenuItem() -> NSMenuItem {
        let keybindingsMenu = NSMenu(title: "Keybindings")

        let hintItem = NSMenuItem(title: "Click a command, then press a new shortcut",
                                  action: nil,
                                  keyEquivalent: "")
        hintItem.isEnabled = false
        keybindingsMenu.addItem(hintItem)
        keybindingsMenu.addItem(.separator())

        for command in CommandRegistry.default.commands {
            let binding = KeybindingStore.resolvedBinding(for: command.identifier)
            let title = "\(command.title)    \(KeybindingStore.displayString(for: binding))"
            let item = NSMenuItem(title: title,
                                  action: #selector(editKeybinding(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command.identifier
            keybindingsMenu.addItem(item)
        }

        keybindingsMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset to Defaults",
                                   action: #selector(resetKeybindings),
                                   keyEquivalent: "")
        resetItem.target = self
        keybindingsMenu.addItem(resetItem)

        let keybindingsItem = NSMenuItem(title: "Keybindings", action: nil, keyEquivalent: "")
        keybindingsItem.submenu = keybindingsMenu
        return keybindingsItem
    }
    
    // MARK: - Appearance
    
    @objc private func setAppearanceSystem() {
        NSApp.appearance = nil
        UserDefaults.standard.set("system", forKey: "appearanceMode")
        updateAppearanceCheckmarks()
    }
    
    @objc private func setAppearanceLight() {
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set("light", forKey: "appearanceMode")
        updateAppearanceCheckmarks()
    }
    
    @objc private func setAppearanceDark() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set("dark", forKey: "appearanceMode")
        updateAppearanceCheckmarks()
    }
    
    private func restoreAppearance() {
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
    
    private func updateAppearanceCheckmarks() {
        guard let menu = appearanceMenu else { return }
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        for item in menu.items {
            switch item.tag {
            case 0: item.state = (mode == "system") ? .on : .off
            case 1: item.state = (mode == "light") ? .on : .off
            case 2: item.state = (mode == "dark") ? .on : .off
            default: item.state = .off
            }
        }
    }
    
    // MARK: - Menu Actions
    
    @objc private func newTab() {
        windowController?.addNewTab()
    }
    
    @objc private func newWindow() {
        windowController?.addNewTab()
    }
    
    @objc private func openFile() {
        windowController?.openFile()
    }
    
    @objc private func saveFile() {
        windowController?.saveFile()
    }
    
    @objc private func saveAsFile() {
        windowController?.saveAsFile()
    }
    
    @objc private func closeTab() {
        windowController?.closeSelectedTab()
    }
    
    @objc private func closeAllTabs() {
        windowController?.closeAllTabs()
    }
    
    @objc private func toggleFindBar() {
        windowController?.toggleFindBar()
    }
    
    @objc private func findNext() {
        windowController?.findNext()
    }
    
    @objc private func findPrevious() {
        windowController?.findPrevious()
    }
    
    @objc private func toggleWordWrap() {
        windowController?.toggleWordWrap()
    }
    
    @objc private func zoomIn() {
        windowController?.zoomIn()
    }
    
    @objc private func zoomOut() {
        windowController?.zoomOut()
    }
    
    @objc private func resetZoom() {
        windowController?.resetZoom()
    }

    // MARK: - Preferences

    /// Standard Cmd+, entry point. The delegate owns the controller, so the
    /// same window is reused for the lifetime of the app instead of stacking
    /// up duplicate preferences windows.
    @objc private func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.targetController = windowController
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func setEOLLF() { windowController?.setEOL("LF") }
    @objc private func setEOLCRLF() { windowController?.setEOL("CRLF") }
    @objc private func setEOLCR() { windowController?.setEOL("CR") }

    @objc private func sortLinesAscending() { windowController?.sortLinesAscending() }
    @objc private func sortLinesDescending() { windowController?.sortLinesDescending() }
    @objc private func removeDuplicateLines() { windowController?.removeDuplicateLines() }
    @objc private func removeBlankLines() { windowController?.removeBlankLines() }

    // MARK: - Keybindings

    /// Rebuilding the entire menu is the single path that applies persisted
    /// overrides to both the Text menu and the Keybindings submenu.
    @objc private func keybindingsDidChange(_ notification: Notification) {
        NSApplication.shared.mainMenu = buildMainMenu()
    }

    @objc private func editKeybinding(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let command = CommandRegistry.default.command(for: identifier) else {
            return
        }

        let current = KeybindingStore.resolvedBinding(for: identifier)
        guard let captured = KeybindingCapture.run(commandTitle: command.title, current: current) else {
            return
        }

        let binding = EditorCommandBinding(identifier: identifier,
                                           keyEquivalent: captured.keyEquivalent,
                                           modifierMask: captured.modifierMask)
        do {
            try KeybindingStore.setOverride(binding)
        } catch {
            showKeybindingError(error)
        }
    }

    @objc private func resetKeybindings() {
        do {
            try KeybindingStore.resetToDefaults()
        } catch {
            showKeybindingError(error)
        }
    }

    private func showKeybindingError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Save Shortcut"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Find in Files

    private var findInFilesController: FindInFilesWindowController?

    @objc private func findInFiles() {
        if findInFilesController == nil {
            let controller = FindInFilesWindowController()
            controller.onOpenMatch = { [weak self] url, range in
                self?.windowController?.openFileAt(url: url, revealing: range)
            }
            findInFilesController = controller
        }
        findInFilesController?.showWindow(nil)
        findInFilesController?.window?.makeKeyAndOrderFront(nil)
    }
    
    @objc private func setLanguage(_ sender: NSMenuItem) {
        let langs = Language.allCases
        guard sender.tag >= 0, sender.tag < langs.count else { return }
        windowController?.setLanguage(langs[sender.tag])
    }
    
    // MARK: - Open Recent
    
    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        windowController?.openFile(atPath: path)
    }
}

// MARK: - NSMenuDelegate (Open Recent)

extension HexpadAppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === playMacroMenu {
            populateMacroList(menu, action: #selector(MainWindowController.playSavedMacro(_:)))
            return
        }
        if menu === deleteMacroMenu {
            populateMacroList(menu, action: #selector(MainWindowController.deleteMacro(_:)))
            return
        }
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()
        
        if recentFilesManager.recents.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }
        
        for path in recentFilesManager.recents {
            let filename = (path as NSString).lastPathComponent
            let item = NSMenuItem(title: filename, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            // Grey out files that no longer exist on disk
            if !FileManager.default.fileExists(atPath: path) {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
    }
}

private extension NSObject {
    func apply(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }
}
