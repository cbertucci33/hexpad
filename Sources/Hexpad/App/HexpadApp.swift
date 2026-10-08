import AppKit
import HexpadKit

@main
class HexpadAppDelegate: NSObject, NSApplicationDelegate {
    
    private var mainWindow: MainWindow?
    private var windowController: MainWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = buildMainMenu()
        
        let window = MainWindow()
        mainWindow = window
        
        let controller = MainWindowController(window: window)
        windowController = controller
        
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        
        restoreSession()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save any modified documents before terminating
        if let wc = windowController {
            // First, save all modified documents with file paths
            for doc in wc.tabStore.documents {
                if doc.isModified, let _ = doc.filePath {
                    try? doc.save()
                }
            }
            // Then save the session state
            wc.saveSession()
        }
        return .terminateNow
    }
    
    // MARK: - Session
    
    private func restoreSession() {
        guard let (tabs, index) = SessionStore.restore() else { return }
        
        // Filter out documents whose files no longer exist on disk
        let validDocs = tabs.documents.filter { doc -> Bool in
            if let path = doc.filePath?.path {
                return FileManager.default.fileExists(atPath: path)
            }
            // Keep untitled docs (they have no file path to validate)
            return true
        }
        
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
    
    // MARK: - Menu
    
    private func buildMainMenu() -> NSMenu {
        let menu = NSMenu()
        
        // App menu
        let appItem = NSMenuItem()
        let appSubMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferencesItem = NSMenuItem(title: "Preferences...", action: nil, keyEquivalent: ",")
        preferencesItem.isEnabled = false
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
        
        fileMenu.addItem(newItem)
        fileMenu.addItem(openItem)
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
        menu.addItem((NSMenuItem(title: "Search", action: nil, keyEquivalent: "").apply { $0.submenu = searchMenu }))
        
        // View menu
        let viewMenu = NSMenu(title: "View")
        let wordWrapItem = NSMenuItem(title: "Word Wrap", action: #selector(toggleWordWrap), keyEquivalent: "y")
        wordWrapItem.target = self
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        let resetZoomItem = NSMenuItem(title: "Reset Zoom", action: #selector(resetZoom), keyEquivalent: "0")
        resetZoomItem.target = self
        
        viewMenu.addItem(wordWrapItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(zoomInItem)
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(resetZoomItem)
        menu.addItem((NSMenuItem(title: "View", action: nil, keyEquivalent: "").apply { $0.submenu = viewMenu }))
        
        // Encoding menu
        let encodingMenu = NSMenu(title: "Encoding")
        let utf8Item = NSMenuItem(title: "UTF-8", action: #selector(setEncodingUTF8), keyEquivalent: "")
        utf8Item.target = self
        let utf16LEItem = NSMenuItem(title: "UTF-16 LE", action: #selector(setEncodingUTF16LE), keyEquivalent: "")
        utf16LEItem.target = self
        let utf16BEItem = NSMenuItem(title: "UTF-16 BE", action: #selector(setEncodingUTF16BE), keyEquivalent: "")
        utf16BEItem.target = self
        let asciiItem = NSMenuItem(title: "ASCII", action: #selector(setEncodingASCII), keyEquivalent: "")
        asciiItem.target = self
        
        encodingMenu.addItem(utf8Item)
        encodingMenu.addItem(utf16LEItem)
        encodingMenu.addItem(utf16BEItem)
        encodingMenu.addItem(asciiItem)
        menu.addItem((NSMenuItem(title: "Encoding", action: nil, keyEquivalent: "").apply { $0.submenu = encodingMenu }))
        
        // Language menu
        let languageMenu = NSMenu(title: "Language")
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.rawValue, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Language.allCases.firstIndex(of: lang) ?? 0
            languageMenu.addItem(item)
        }
        menu.addItem((NSMenuItem(title: "Language", action: nil, keyEquivalent: "").apply { $0.submenu = languageMenu }))
        
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
        menu.addItem((NSMenuItem(title: "Window", action: nil, keyEquivalent: "").apply { $0.submenu = windowMenu }))
        
        // Help menu
        let helpMenu = NSMenu(title: "Help")
        let aboutHexpad = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        helpMenu.addItem(aboutHexpad)
        menu.addItem((NSMenuItem(title: "Help", action: nil, keyEquivalent: "").apply { $0.submenu = helpMenu }))
        
        NSApplication.shared.menu = menu
        return menu
    }
    
    // MARK: - Menu Actions
    
    @objc private func newTab() {
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
    
    @objc private func setEncodingUTF8() {
        windowController?.setEncoding("UTF-8")
    }
    
    @objc private func setEncodingUTF16LE() {
        windowController?.setEncoding("UTF-16LE")
    }
    
    @objc private func setEncodingUTF16BE() {
        windowController?.setEncoding("UTF-16BE")
    }
    
    @objc private func setEncodingASCII() {
        windowController?.setEncoding("ASCII")
    }
    
    @objc private func setLanguage(_ sender: NSMenuItem) {
        let langs = Language.allCases
        guard sender.tag >= 0, sender.tag < langs.count else { return }
        windowController?.setLanguage(langs[sender.tag])
    }
}

private extension NSObject {
    func apply(_ block: (Self) -> Void) -> Self {
        block(self)
        return self
    }
}
