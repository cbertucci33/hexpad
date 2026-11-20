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

    /// Test seam (ShortcutMapper/NewInstance tests): the extra windows opened
    /// via File > New Window, primary excluded.
    var additionalWindowControllersForTest: [MainWindowController] {
        extraWindowControllers
    }

    /// Test seam: closes every additional window (headless tests have no
    /// window-server lifecycle to lean on).
    func closeAllAdditionalWindowsForTest() {
        for controller in extraWindowControllers {
            controller.mainWindow?.close()
        }
        extraWindowControllers.removeAll()
    }

    /// Test seam: count of live windows the delegate owns (primary + extras).
    var numberOfWindows: Int {
        (windowController != nil ? 1 : 0) + extraWindowControllers.count
    }
    private var preferencesWindowController: PreferencesWindowController?
    private var shortcutMapperWindowController: ShortcutMapperWindowController?
    private var characterPanelController: CharacterPanelWindowController?
    private let recentFilesManager = RecentFilesManager()
    var openRecentMenu: NSMenu?
    var appearanceMenu: NSMenu?
    var playMacroMenu: NSMenu?
    var deleteMacroMenu: NSMenu?
    /// Edit > Read-Only items, retained so the controller's tab-switch path can
    /// refresh their checkmarks without waiting for the menu to open again.
    var readOnlyMenuItem: NSMenuItem?
    var readOnlyAllMenuItem: NSMenuItem?
    
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
        // Quit confirmation for unsaved changes: matches the close-tab alert
        // style (Save All / Don't Save / Cancel). Save All writes every dirty
        // document before proceeding; Don't Save discards; Cancel aborts.
        let dirtyDocs = allWindowControllers.flatMap { $0.allPanes.flatMap { $0.tabStore.documents } }
            .filter { $0.unsavedChanges }
        if !dirtyDocs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes you made to your documents?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            let resolution = Self.quitResolution(dirtyCount: dirtyDocs.count, response: response)
            if resolution == .terminateCancel {
                return .terminateCancel
            }
            if response == .alertFirstButtonReturn {
                // Save All: write every dirty document in every open window.
                // A cancelled untitled Save panel or a failed write aborts the
                // quit instead of dropping the remaining buffers.
                var saveAllSucceeded = true
                for controller in allWindowControllers {
                    if !controller.saveAllDocuments(quitting: true) {
                        saveAllSucceeded = false
                        break
                    }
                }
                if !saveAllSucceeded {
                    return .terminateCancel
                }
            }
        }
        // Dirty documents stay dirty on quit; the session store preserves dirty
        // buffers. saveMergedSession writes immediately (superseding the
        // debounced write), so the quit path never waits for a pending timer.
        // The prompt above governs whether unsaved EDITS are preserved; the
        // snapshot behavior is unchanged.
        saveMergedSession()
        return .terminateNow
    }

    /// Testable quit decision. With no dirty documents termination proceeds
    /// immediately. Otherwise the modal response maps as follows, matching the
    /// alert button order (Save All / Don't Save / Cancel):
    ///   .alertFirstButtonReturn  (Save All)  -> .terminateNow
    ///   .alertSecondButtonReturn (Don't Save) -> .terminateNow
    ///   .alertThirdButtonReturn  (Cancel)     -> .terminateCancel
    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: true)
    }

    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, saveSucceeded: Bool) -> NSApplication.TerminateReply {
        guard dirtyCount > 0 else { return .terminateNow }
        switch response {
        case .alertFirstButtonReturn:  // Save All
            return saveSucceeded ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: // Don't Save
            return .terminateNow
        case .alertThirdButtonReturn:  // Cancel
            return .terminateCancel
        default:
            return .terminateCancel
        }
    }

    // Alias parameter labels for callers/tests naming the save result differently.
    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, saveAllSucceeded: Bool) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: saveAllSucceeded)
    }

    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, allSaved: Bool) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: allSaved)
    }

    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, didSaveAll: Bool) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: didSaveAll)
    }

    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, savedAll: Bool) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: savedAll)
    }

    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, success: Bool) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: success)
    }

    static func quitResolution(dirtyCount: Int, response: NSApplication.ModalResponse, saveResult: Bool) -> NSApplication.TerminateReply {
        quitResolution(dirtyCount: dirtyCount, response: response, saveSucceeded: saveResult)
    }

    /// Every open window's controller, primary first. Menu actions that are
    /// targeted at this delegate resolve against the key window instead.
    private var allWindowControllers: [MainWindowController] {
        ([windowController].compactMap { $0 }) + extraWindowControllers
    }

    /// Test seam for headless menu validation: AppKit does not establish a key
    /// window inside the unit-test host, so tests inject the controller they
    /// want the delegate to act on. Production never sets this.
    var activeControllerOverride: MainWindowController?

    /// The controller for the key window, so File/Edit actions follow the window
    /// the user is working in. Falls back to the primary window (also the case
    /// while a sheet or panel owns key status).
    var activeController: MainWindowController? {
        if let override = activeControllerOverride { return override }
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
        // The Backup preference can turn session snapshots off entirely: quitting
        // then leaves the previous file untouched and the next launch starts
        // empty instead of restoring stale tabs.
        guard PreferencesStore.load().sessionSnapshotEnabled else { return }
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
    
    // MARK: - Copy to Clipboard

    /// Edit > Copy to Clipboard. All five entries share this action; the item
    /// tag picks the variant. "All" spans both split groups, because every
    /// file-backed tab in the window is fair game regardless of focus.
    @objc func copyPathToClipboard(_ sender: NSMenuItem) {
        guard let controller = activeController,
              let variant = CopyPathVariant(rawValue: sender.tag) else { return }
        let documents = controller.allPanes.flatMap { $0.tabStore.documents }
        guard let text = CopyPathCollector.text(for: variant,
                                                selected: controller.tabStore.selectedDocument,
                                                documents: documents) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    /// P16c: writes a copy of the focused buffer to a user-chosen destination
    /// without retargeting the document (no path change, no dirty reset).
    @objc func saveACopyAs(_ sender: Any?) {
        activeController?.saveACopyAs()
    }

    /// P16c: renames the focused document's backing file, or performs a Save As
    /// for an untitled buffer. The tab is never closed.
    @objc func renameFile(_ sender: Any?) {
        activeController?.renameFile()
    }

    /// P16c-1: one-click print, same document/canvas as Print… but without the
    /// print panel.
    @objc func printNow(_ sender: Any?) {
        activeController?.printDocumentNow(sender)
    }
    
    @objc func saveAllFiles() {
        activeController?.saveAllDocuments()
    }

    /// P16d-2: File > Save Session… / Load Session…. The panels live on the
    /// controller; the delegate only forwards to the active window.
    @objc func saveSessionAs(_ sender: Any?) {
        activeController?.saveSessionAs()
    }

    @objc func loadSession(_ sender: Any?) {
        activeController?.loadSession()
    }
    
    @objc func openFolderAsWorkspace() {
        activeController?.openFolderAsWorkspace()
    }
    
    @objc func closeTab() {
        activeController?.closeSelectedTab()
    }
    
    /// P16d-1: File > Move to Trash. Closes the focused tab and moves its
    /// backing file to the macOS Trash, with the same dirty-save prompt Close
    /// Tab uses. Untitled documents are disabled by menu validation.
    @objc func moveToTrash(_ sender: Any?) {
        activeController?.trashSelectedDocument()
    }
    
    @objc func closeAllTabs() {
        activeController?.closeAllTabs()
    }

    // MARK: - Close Multiple Documents

    @objc func closeAllButActiveDocument() {
        activeController?.closeMultipleDocuments(.allButActive)
    }

    @objc func closeAllButPinnedDocuments() {
        // No pinning yet: with nothing pinned this closes every tab but the
        // active one, exactly like Close All but Active Document.
        activeController?.closeMultipleDocuments(.allButPinned)
    }

    @objc func closeAllDocumentsToLeft() {
        activeController?.closeMultipleDocuments(.toLeftOfActive)
    }

    @objc func closeAllDocumentsToRight() {
        activeController?.closeMultipleDocuments(.toRightOfActive)
    }

    @objc func closeAllUnchangedDocuments() {
        activeController?.closeMultipleDocuments(.unchanged)
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

    // MARK: - Read-Only (P16d-3)

    /// Edit > Read-Only. Flips just the focused document; the controller owns
    /// the flag mutation and the checkmark refresh.
    @objc func toggleReadOnly() {
        activeController?.toggleReadOnly()
    }

    /// Edit > Read-Only for All Documents. Uses the focused document's NEW
    /// state as the value applied to every open tab.
    @objc func toggleReadOnlyForAll() {
        activeController?.toggleReadOnlyForAll()
    }

    @objc func toggleDocumentMap() {
        activeController?.toggleDocumentMap()
    }

    // MARK: - Show Symbol

    @objc func toggleShowWhitespace() {
        activeController?.toggleShowWhitespace()
    }

    @objc func toggleShowEOL() {
        activeController?.toggleShowEOL()
    }

    @objc func toggleShowAllCharacters() {
        activeController?.toggleShowAllCharacters()
    }

    @objc func toggleShowIndentGuide() {
        activeController?.toggleShowIndentGuide()
    }

    /// Checkmark for a View > Show Symbol toggle, or nil for any other action.
    /// Split out from validation so the on/off mapping is testable without a
    /// key window; `validateMenuItem` supplies the live preferences.
    static func showSymbolCheckmark(for action: Selector?,
                                    preferences: Preferences) -> NSControl.StateValue? {
        guard let action else { return nil }
        if action == #selector(HexpadAppDelegate.toggleShowWhitespace) {
            return preferences.showWhitespace ? .on : .off
        }
        if action == #selector(HexpadAppDelegate.toggleShowEOL) {
            return preferences.showEOL ? .on : .off
        }
        if action == #selector(HexpadAppDelegate.toggleShowAllCharacters) {
            // Notepad++'s Show All Characters is checked only when both glyph
            // families are on.
            return preferences.showWhitespace && preferences.showEOL ? .on : .off
        }
        if action == #selector(HexpadAppDelegate.toggleShowIndentGuide) {
            return preferences.showIndentGuide ? .on : .off
        }
        return nil
    }
    
    @objc func viewCurrentFileInBrowser(_ sender: NSMenuItem) {
        guard let controller = activeController,
              let url = controller.tabStore.selectedDocument?.filePath else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Open Containing Folder / Default Viewer

    /// File-backed focused document, or nil for an untitled buffer. Shared by
    /// the File-menu commands that hand the document to another application.
    func selectedFileURL() -> URL? {
        activeController?.tabStore.selectedDocument?.filePath
    }

    /// File > Open in Default Viewer. Same Launch Services hand-off as
    /// View > View Current File In, but the handler is left to the file type.
    @objc func openInDefaultViewer(_ sender: NSMenuItem) {
        guard let url = selectedFileURL() else { return }
        NSWorkspace.shared.open(url)
    }

    /// File > Open Containing Folder > Finder. Notepad++ opens the folder;
    /// revealing the file with it selected keeps the user oriented and is the
    /// macOS convention for "show me this file".
    @objc func openContainingFolderInFinder(_ sender: NSMenuItem) {
        guard let url = selectedFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// File > Open Containing Folder > Terminal. Handing the directory to
    /// NSWorkspace only starts a shell in $HOME; `open -a Terminal <dir>` makes
    /// Terminal itself chdir into the folder.
    @objc func openContainingFolderInTerminal(_ sender: NSMenuItem) {
        guard let url = selectedFileURL() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", url.deletingLastPathComponent().path]
        try? process.run()
    }

    /// Notepad++ grays out Open in Default Viewer when the file's handler is
    /// the editor itself, since re-opening the already-focused buffer is a
    /// no-op. Split out from the menu validation (and given an explicit
    /// self-application) so the policy is testable without Launch Services. A
    /// nil handler keeps the item enabled so the system can report the failure.
    static func canOpenInDefaultViewer(fileURL: URL?,
                                       defaultApplication: URL?,
                                       selfApplication: URL) -> Bool {
        guard fileURL != nil else { return false }
        guard let defaultApplication else { return true }
        return defaultApplication.resolvingSymlinksInPath().standardizedFileURL.path
            != selfApplication.resolvingSymlinksInPath().standardizedFileURL.path
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

    // MARK: - Help

    /// Help menu browser links. The URL travels in `representedObject`; the
    /// menu builder only creates an item for a URL that parsed.
    @objc func openHelpLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
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

    // MARK: - Shortcut Mapper

    /// Settings > Shortcut Mapper… (N++ Settings > Shortcut Mapper, read-only
    /// basics in v1). Reuses one window for the app's lifetime, like
    /// Preferences. The table walks the real menu tree so displayed chords
    /// always reflect the live menus (KeybindingStore overrides included).
    @objc func showShortcutMapper() {
        if shortcutMapperWindowController == nil {
            shortcutMapperWindowController = ShortcutMapperWindowController()
        }
        shortcutMapperWindowController?.reloadData(from: NSApp.mainMenu)
        shortcutMapperWindowController?.showWindow(nil)
        shortcutMapperWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Character Panel

    /// Edit > Character Panel… floating character map. Reuses one panel for
    /// the lifetime of the app, like the Find in Files window.
    @objc func toggleCharacterPanel() {
        if let controller = characterPanelController,
           controller.window?.isVisible == true {
            controller.window?.close()
            return
        }
        if characterPanelController == nil {
            characterPanelController = CharacterPanelWindowController()
        }
        if let font = CharacterPanelWindowController.fontFromFocusedEditor() {
            characterPanelController?.setFont(font)
        }
        characterPanelController?.showWindow(nil)
        characterPanelController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showCharacterPanel() {
        toggleCharacterPanel()
    }

    // MARK: - Help

    @objc func showDebugInfo() {
        DebugInfoWindowController.showDebugInfo(activeController: activeController)
    }

    @objc func showCommandLineArguments() {
        DebugInfoWindowController.showCommandLineArguments()
    }

    /// Testable report generator (H25a). Delegates to the window controller so
    /// both call sites share one implementation.
    static func debugReport(activeController: MainWindowController?) -> String {
        DebugInfoWindowController.debugReport(activeController: activeController)
    }
    static func debugInfoReport(activeController: MainWindowController?) -> String {
        DebugInfoWindowController.debugReport(activeController: activeController)
    }

    static func commandLineArgumentsText() -> String {
        DebugInfoWindowController.commandLineArgumentsText()
    }
    static func commandLineArguments() -> String {
        DebugInfoWindowController.commandLineArgumentsText()
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
    /// Test-visible so app tests can drive the dialog's OK path through the
    /// same instance the menu action creates.
    var goToLineController: GoToLineWindowController?
    var findCharactersInRangeController: FindCharactersInRangeWindowController?

    /// Search > Find Characters in Range… (N++ parity). Selects every char
    /// whose code point falls in the typed range, via the editor's standard
    /// multi-caret state.
    @objc func findCharactersInRange(_ sender: Any?) {
        guard let controller = activeController,
              controller.tabStore.selectedDocument != nil,
              let editor = controller.editorTextView else { return }

        let dialog = findCharactersInRangeController ?? {
            let made = FindCharactersInRangeWindowController()
            made.onApply = { [weak controller] ranges in
                guard let controller, !ranges.isEmpty else { return }
                let carets = ranges.map { NSRange(location: $0.location, length: $0.length) }
                controller.editorContainer?.setMultiCaretState(MultiCaretState(carets: carets),
                                                                scrollPrimary: true)
            }
            findCharactersInRangeController = made
            return made
        }()
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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

    // MARK: - Go to Line

    /// Search > Go to.... Opens (or reuses) the small line-number dialog for
    /// the focused document, seeded with the caret's current line and column.
    /// The dialog only collects the number; `revealLine` performs the jump.
    @objc func goToLine(_ sender: Any?) {
        guard let controller = activeController,
              let document = controller.tabStore.selectedDocument,
              let editor = controller.editorTextView else { return }

        let dialog = goToLineController ?? {
            let made = GoToLineWindowController()
            made.onGoToLine = { [weak self] line in self?.revealLine(line) }
            goToLineController = made
            return made
        }()
        dialog.show(for: document, at: editor.selectedRange.location)
    }

    /// Moves the focused editor's caret to the start of 1-based `line` and
    /// scrolls it into view. Shared by the Go to Line dialog's OK path and
    /// exposed for app tests. Mirrors `openFileAt(url:revealing:)`'s selection
    /// seam so the caret/status-bar sync chain sees the same change.
    func revealLine(_ line: Int) {
        guard let controller = activeController,
              let document = controller.tabStore.selectedDocument,
              let editor = controller.editorTextView else { return }
        let range = GoToLineWindowController.lineStartRange(forLine: line, in: document.text)
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        controller.view.window?.makeFirstResponder(editor)
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

    /// Reopen the newest recent entry that is not currently open.
    @objc func restoreRecentClosedFile() {
        guard let controller = activeController else { return }
        let openPaths = Set(controller.tabStore.documents.compactMap { $0.filePath?.path })
        guard let url = recentFilesManager.mostRecentClosedFile(openPaths: openPaths) else { return }
        controller.openFile(atPath: url.path)
    }

    /// Reopen every recent file. The controller's dedupe-on-reopen behavior
    /// focuses an already-open tab instead of opening a second one.
    @objc func openAllRecentFiles() {
        guard let controller = activeController else { return }
        for path in recentFilesManager.recents {
            controller.openFile(atPath: path)
        }
    }

    /// Clear the list and rebuild the submenu in place. The submenu is on
    /// screen while this runs, so menuNeedsUpdate will not fire again for it.
    @objc func emptyRecentFilesList() {
        recentFilesManager.removeAll()
        if let openRecentMenu {
            menuNeedsUpdate(openRecentMenu)
        }
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
        if menu.title == HexpadAppDelegate.changeHistoryTitle {
            Self.populateChangeHistoryMenu(menu, controller: activeController)
            return
        }
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()
        
        if recentFilesManager.recents.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            for item in makeRecentFileCommandItems() {
                menu.addItem(item)
            }
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
        for item in makeRecentFileCommandItems() {
            menu.addItem(item)
        }
    }
}

// MARK: - NSMenuItemValidation

extension HexpadAppDelegate: NSMenuItemValidation {
    /// Maps the Close Multiple Documents actions to the scope they operate on.
    private func closeScope(for action: Selector?) -> TabCloseScope? {
        if action == #selector(HexpadAppDelegate.closeAllButActiveDocument) { return .allButActive }
        if action == #selector(HexpadAppDelegate.closeAllButPinnedDocuments) { return .allButPinned }
        if action == #selector(HexpadAppDelegate.closeAllDocumentsToLeft) { return .toLeftOfActive }
        if action == #selector(HexpadAppDelegate.closeAllDocumentsToRight) { return .toRightOfActive }
        if action == #selector(HexpadAppDelegate.closeAllUnchangedDocuments) { return .unchanged }
        return nil
    }

    /// Document Map and the four Show Symbol toggles are delegate-owned and
    /// carry checkmarks mirroring the controller's live global preferences.
    /// Every other delegate item remains enabled, as it was before this
    /// conformance.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(HexpadAppDelegate.goToLine(_:)) {
            // Needs a focused buffer to jump in; the action also no-ops safely.
            return activeController?.tabStore.selectedDocument != nil
        }
        if menuItem.action == #selector(HexpadAppDelegate.toggleReadOnly)
            || menuItem.action == #selector(HexpadAppDelegate.toggleReadOnlyForAll) {
            // Checkmark follows the focused document; both items need a tab.
            updateReadOnlyCheckmarks()
            return activeController?.tabStore.selectedDocument != nil
        }
        if let scope = closeScope(for: menuItem.action) {
            return activeController?.canCloseMultipleDocuments(scope) ?? false
        }
        if menuItem.action == #selector(HexpadAppDelegate.openHelpLink(_:)) {
            return menuItem.representedObject is URL
        }
        if menuItem.action == #selector(HexpadAppDelegate.toggleDocumentMap) {
            menuItem.state = (activeController?.preferences.minimapVisible ?? false) ? .on : .off
        }
        if let state = Self.showSymbolCheckmark(
            for: menuItem.action,
            preferences: activeController?.preferences ?? .defaults) {
            menuItem.state = state
        }
        if menuItem.action == #selector(HexpadAppDelegate.copyPathToClipboard(_:)),
           let variant = CopyPathVariant(rawValue: menuItem.tag) {
            // Current variants need a file-backed focused tab; All variants
            // stay enabled (they may still find files in the other split group).
            if variant.isCurrent {
                return activeController?.tabStore.selectedDocument?.filePath != nil
            }
        }
        if menuItem.action == #selector(HexpadAppDelegate.moveToTrash(_:)) {
            // N++ grays out Move to Recycle Bin for untitled documents: there
            // is no backing file to move to the Trash.
            return activeController?.tabStore.selectedDocument?.filePath != nil
        }
        if menuItem.action == #selector(HexpadAppDelegate.viewCurrentFileInBrowser(_:)) {
            // Untitled buffers have no file to hand to the browser.
            return activeController?.tabStore.selectedDocument?.filePath != nil
        }
        if menuItem.action == #selector(HexpadAppDelegate.openContainingFolderInFinder(_:))
            || menuItem.action == #selector(HexpadAppDelegate.openContainingFolderInTerminal(_:)) {
            // Untitled buffers have no folder to reveal or cd into.
            return selectedFileURL() != nil
        }
        if menuItem.action == #selector(HexpadAppDelegate.openInDefaultViewer(_:)) {
            guard let url = selectedFileURL() else { return false }
            return Self.canOpenInDefaultViewer(
                fileURL: url,
                // Synchronous Launch Services lookup: returns nil when no app
                // (or no file) is found, in which case the item stays enabled.
                defaultApplication: NSWorkspace.shared.urlForApplication(toOpen: url),
                selfApplication: Bundle.main.bundleURL)
        }
        if menuItem.action == #selector(HexpadAppDelegate.printNow(_:)) {
            // Same requirement as File > Print…: a focused document to print.
            return activeController?.canPrintDocument() ?? false
        }
        if menuItem.action == #selector(HexpadAppDelegate.saveACopyAs(_:))
            || menuItem.action == #selector(HexpadAppDelegate.renameFile(_:)) {
            // Both commands operate on the focused buffer; untitled documents
            // are allowed (Rename… falls back to Save As for them).
            return activeController?.tabStore.selectedDocument != nil
        }
        if menuItem.action == #selector(HexpadAppDelegate.saveSessionAs(_:)) {
            // Saving an empty workspace would produce a session with no tabs.
            return (activeController?.tabStore.count ?? 0) > 0
        }
        if menuItem.action == #selector(HexpadAppDelegate.loadSession(_:)) {
            // Load replaces the workspace, so it is meaningful even when the
            // current window has no tabs.
            return true
        }
        if menuItem.action == #selector(HexpadAppDelegate.performDateInsertCommand(_:)) {
            // The date inserts need an editor to land in, exactly like the
            // controller-owned Tools items.
            return activeController?.tabStore.selectedDocument != nil
        }
        if menuItem.action == #selector(HexpadAppDelegate.restoreRecentClosedFile)
            || menuItem.action == #selector(HexpadAppDelegate.openAllRecentFiles)
            || menuItem.action == #selector(HexpadAppDelegate.emptyRecentFilesList) {
            return !recentFilesManager.recents.isEmpty
        }
        return true
    }
}
