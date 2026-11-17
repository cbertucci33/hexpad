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
    /// Windows opened with File > New Window. Retained here so their editors and
    /// watchers stay alive; removed when the window closes.
    private var extraWindowControllers: [MainWindowController] = []
    private var preferencesWindowController: PreferencesWindowController?
    private let recentFilesManager = RecentFilesManager()
    var openRecentMenu: NSMenu?
    var appearanceMenu: NSMenu?
    var playMacroMenu: NSMenu?
    var deleteMacroMenu: NSMenu?
    
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
        // Dirty documents stay dirty on quit; the session store preserves dirty
        // buffers. saveMergedSession writes immediately (superseding the
        // debounced write), so the quit path never waits for a pending timer.
        saveMergedSession()
        return .terminateNow
    }

    /// Every open window's controller, primary first. Menu actions that are
    /// targeted at this delegate resolve against the key window instead.
    private var allWindowControllers: [MainWindowController] {
        ([windowController].compactMap { $0 }) + extraWindowControllers
    }

    /// The controller for the key window, so File/Edit actions follow the window
    /// the user is working in. Falls back to the primary window (also the case
    /// while a sheet or panel owns key status).
    private var activeController: MainWindowController? {
        if let controller = NSApp.keyWindow?.contentViewController as? MainWindowController {
            return controller
        }
        return windowController
    }

    /// Writes one session containing every open window's tabs.
    ///
    /// Snapshots are built here, on the main thread, and handed to
    /// `SessionStore` as finished dictionaries. Additional windows skip their
    /// own scheduled writes (`isAdditionalWindow`), so this is the only path
    /// that can persist their buffers.
    private func saveMergedSession() {
        let controllers = allWindowControllers
        guard !controllers.isEmpty else { return }
        for controller in controllers {
            controller.captureSessionState()
        }
        let snapshots = controllers.map { $0.sessionSnapshot() }
        let merged = SessionStore.Snapshot(tabs: snapshots.flatMap { $0.tabs },
                                           selectedIndex: snapshots.first?.selectedIndex ?? 0)
        try? SessionStore.save(merged)
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

        let appItem = NSMenuItem()
        appItem.submenu = makeAppMenu()
        menu.addItem(appItem)

        menu.addItem(topLevelMenuItem(title: "File", submenu: makeFileMenu()))
        menu.addItem(topLevelMenuItem(title: "Edit", submenu: makeEditMenu()))
        menu.addItem(topLevelMenuItem(title: "Text", submenu: makeTextMenu()))
        menu.addItem(topLevelMenuItem(title: "Search", submenu: makeSearchMenu()))
        menu.addItem(topLevelMenuItem(title: "View", submenu: makeViewMenu()))
        menu.addItem(topLevelMenuItem(title: "Encoding", submenu: makeEncodingMenu()))
        menu.addItem(topLevelMenuItem(title: "Line Ops", submenu: makeLineOpsMenu()))
        menu.addItem(topLevelMenuItem(title: "Language", submenu: makeLanguageMenu()))
        menu.addItem(topLevelMenuItem(title: "Macro", submenu: makeMacroMenu()))
        menu.addItem(topLevelMenuItem(title: "Run", submenu: makeRunMenu()))
        menu.addItem(topLevelMenuItem(title: "Tools", submenu: makeToolsMenu()))
        menu.addItem(topLevelMenuItem(title: "Window", submenu: makeWindowMenu()))
        menu.addItem(topLevelMenuItem(title: "Help", submenu: makeHelpMenu()))

        NSApplication.shared.menu = menu
        return menu
    }

    /// Wraps a section's submenu in the untitled, actionless top-level item
    /// AppKit expects, under the title the menu bar shows.
    private func topLevelMenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
    
    // MARK: - Appearance
    
    @objc func setAppearanceSystem() {
        NSApp.appearance = nil
        UserDefaults.standard.set("system", forKey: "appearanceMode")
        updateAppearanceCheckmarks()
    }
    
    @objc func setAppearanceLight() {
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set("light", forKey: "appearanceMode")
        updateAppearanceCheckmarks()
    }
    
    @objc func setAppearanceDark() {
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
    
    func updateAppearanceCheckmarks() {
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
    
    @objc func newTab() {
        activeController?.addNewTab()
    }
    
    @objc func newWindow() {
        // A real second window (Notepad++ File > New Window), not another tab.
        // It owns its own tab groups, editors and watchers; the primary
        // controller keeps the session writes and the quit path merges all
        // windows into one snapshot.
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        controller.isAdditionalWindow = true
        controller.recentFilesManager = recentFilesManager
        window.contentViewController = controller
        window.delegate = self
        extraWindowControllers.append(controller)
        window.makeKeyAndOrderFront(nil)
        controller.applyPreferences()
    }
    
    @objc func openFile() {
        activeController?.openFile()
    }
    
    @objc func saveFile() {
        activeController?.saveFile()
    }
    
    @objc func saveAsFile() {
        activeController?.saveAsFile()
    }
    
    @objc func saveAllFiles() {
        activeController?.saveAllDocuments()
    }
    
    @objc func openFolderAsWorkspace() {
        activeController?.openFolderAsWorkspace()
    }
    
    @objc func closeTab() {
        activeController?.closeSelectedTab()
    }
    
    @objc func closeAllTabs() {
        activeController?.closeAllTabs()
    }
    
    @objc func toggleFindBar() {
        activeController?.toggleFindBar()
    }
    
    @objc func findNext() {
        activeController?.findNext()
    }
    
    @objc func findPrevious() {
        activeController?.findPrevious()
    }
    
    @objc func toggleWordWrap() {
        activeController?.toggleWordWrap()
    }

    @objc func toggleDocumentMap() {
        activeController?.toggleDocumentMap()
    }
    
    @objc func zoomIn() {
        activeController?.zoomIn()
    }
    
    @objc func zoomOut() {
        activeController?.zoomOut()
    }
    
    @objc func resetZoom() {
        activeController?.resetZoom()
    }

    // MARK: - Preferences

    /// Standard Cmd+, entry point. The delegate owns the controller, so the
    /// same window is reused for the lifetime of the app instead of stacking
    /// up duplicate preferences windows.
    @objc func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.targetController = activeController
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func setEOLLF() { activeController?.setEOL("LF") }
    @objc func setEOLCRLF() { activeController?.setEOL("CRLF") }
    @objc func setEOLCR() { activeController?.setEOL("CR") }

    @objc private func sortLinesAscending() { activeController?.sortLinesAscending() }
    @objc private func sortLinesDescending() { activeController?.sortLinesDescending() }
    @objc private func removeDuplicateLines() { activeController?.removeDuplicateLines() }
    @objc private func removeBlankLines() { activeController?.removeBlankLines() }

    // MARK: - Keybindings

    /// Rebuilding the entire menu is the single path that applies persisted
    /// overrides to both the Text menu and the Keybindings submenu.
    @objc private func keybindingsDidChange(_ notification: Notification) {
        NSApplication.shared.mainMenu = buildMainMenu()
    }

    @objc func editKeybinding(_ sender: NSMenuItem) {
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

    @objc func resetKeybindings() {
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

    @objc func findInFiles() {
        if findInFilesController == nil {
            let controller = FindInFilesWindowController()
            controller.onOpenMatch = { [weak self] url, range in
                self?.activeController?.openFileAt(url: url, revealing: range)
            }
            findInFilesController = controller
        }
        findInFilesController?.showWindow(nil)
        findInFilesController?.window?.makeKeyAndOrderFront(nil)
    }
    
    @objc func setLanguage(_ sender: NSMenuItem) {
        let langs = Language.allCases
        guard sender.tag >= 0, sender.tag < langs.count else { return }
        activeController?.setLanguage(langs[sender.tag])
    }
    
    // MARK: - Open Recent
    
    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        activeController?.openFile(atPath: path)
    }

    // MARK: - External open (Finder, `open`, drag onto dock icon)

    /// Files handed to us by Launch Services. Without this the bundle has no
    /// open handler, so `open -a Hexpad file.txt` fails with "cannot open
    /// files in the ... format" before our code ever runs.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Ensure at least one window exists so a cold `open -a Hexpad x.py`
        // lands the file in a real editor rather than nowhere (app can launch
        // without windows when launched directly with files and no session).
        if windowController == nil {
            let window = MainWindow()
            mainWindow = window
            let controller = MainWindowController(window: window)
            window.contentViewController = controller
            controller.recentFilesManager = recentFilesManager
            controller.applyPreferences()
            window.makeKeyAndOrderFront(nil)
            windowController = controller
        }
        for url in urls {
            activeController?.openFile(atPath: url.path)
        }
    }
}

// MARK: - NSWindowDelegate (additional windows)

extension HexpadAppDelegate: NSWindowDelegate {
    /// Closing any window persists the whole app's tabs before the window leaves
    /// the controller registry, so a second window's buffers are restored on the
    /// next launch instead of being dropped. Releases the controller's strong
    /// window reference so a closed additional window can deallocate (the window
    /// retains its content view controller, which would otherwise be a cycle).
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let isPrimary = window === mainWindow
        let extraIndex = extraWindowControllers.firstIndex { $0.view.window === window }
        guard isPrimary || extraIndex != nil else { return }

        saveMergedSession()

        if let extraIndex {
            let closing = extraWindowControllers.remove(at: extraIndex)
            closing.releaseWindowReference()
        }
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

// MARK: - NSMenuItemValidation

extension HexpadAppDelegate: NSMenuItemValidation {
    /// Document Map is the one delegate-owned toggle with a checkmark; its
    /// state mirrors the controller's live global preference. Every other
    /// delegate item remains enabled, as it was before this conformance.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(HexpadAppDelegate.toggleDocumentMap) {
            menuItem.state = (activeController?.preferences.minimapVisible ?? false) ? .on : .off
        }
        return true
    }
}
