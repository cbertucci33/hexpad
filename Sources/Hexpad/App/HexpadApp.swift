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
    private let recentFilesManager = RecentFilesManager()
    private var openRecentMenu: NSMenu?
    private var appearanceMenu: NSMenu?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreAppearance()
        NSApplication.shared.mainMenu = buildMainMenu()
        
        let window = MainWindow()
        mainWindow = window
        
        let controller = MainWindowController(window: window)
        windowController = controller
        
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        
        controller.recentFilesManager = recentFilesManager
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
        
        // Open Recent submenu
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        self.openRecentMenu = openRecentMenu
        
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
        viewMenu.addItem(.separator())
        viewMenu.addItem(zoomInItem)
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(resetZoomItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(appearanceItem)
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

        // Line operations menu: LineOps was fully implemented and unit-tested
        // but unreachable from the app.
        let lineOpsMenu = NSMenu(title: "Line Operations")
        for (title, sel) in [("Sort Lines A-Z", #selector(sortLinesAscending)),
                             ("Sort Lines Z-A", #selector(sortLinesDescending)),
                             ("Remove Duplicate Lines", #selector(removeDuplicateLines)),
                             ("Remove Blank Lines", #selector(removeBlankLines))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
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

    @objc private func setEOLLF() { windowController?.setEOL("LF") }
    @objc private func setEOLCRLF() { windowController?.setEOL("CRLF") }
    @objc private func setEOLCR() { windowController?.setEOL("CR") }

    @objc private func sortLinesAscending() { windowController?.sortLinesAscending() }
    @objc private func sortLinesDescending() { windowController?.sortLinesDescending() }
    @objc private func removeDuplicateLines() { windowController?.removeDuplicateLines() }
    @objc private func removeBlankLines() { windowController?.removeBlankLines() }
    
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
