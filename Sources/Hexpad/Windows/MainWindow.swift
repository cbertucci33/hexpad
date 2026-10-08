import SwiftUI
import AppKit
import HexpadKit

struct MainWindow: View {
    @ObservedObject var tabStore: TabStore
    @Binding var theme: HexpadTheme
    @Binding var showFindBar: Bool
    
    @State private var searchText = ""
    @State private var replaceText = ""
    @State private var searchOptions: SearchOptions = []
    @State private var findMatchIndex = 0
    @State private var findTotalMatches = 0
    
    var body: some View {
        VStack(spacing: 0) {
            TabBar(tabStore: tabStore)
                .background(Color(NSColor.controlBackgroundColor))
            
            if let doc = tabStore.selectedDocument {
                EditorView(
                    document: doc,
                    theme: theme,
                    showFindBar: showFindBar
                )
            } else {
                Spacer()
                Text("No file open")
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            StatusBar(tabStore: tabStore)
                .background(Color(NSColor.controlBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { showFindBar.toggle() }) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find and Replace")
            }
        }
        .overlay(alignment: .top) {
            if showFindBar {
                FindBar(
                    searchText: $searchText,
                    replaceText: $replaceText,
                    options: $searchOptions,
                    onFind: {
                        findMatches()
                    },
                    onReplace: {
                        replaceNext()
                    },
                    onReplaceAll: {
                        replaceAll()
                    },
                    onClose: {
                        showFindBar = false
                    }
                )
            }
        }
        .onAppear {
            setupMenuBar()
        }
    }
    
    private func findMatches() {
        guard let text = tabStore.selectedDocument?.text else { return }
        let matches = SearchEngine.search(text, pattern: searchText, options: searchOptions)
        findTotalMatches = matches.count
        findMatchIndex = matches.isEmpty ? 0 : 1
    }
    
    private func replaceNext() {
        guard let doc = tabStore.selectedDocument, !searchText.isEmpty else { return }
        let matches = SearchEngine.search(doc.text, pattern: searchText, options: searchOptions)
        if let match = matches.sorted(by: { $0.range.location < $1.range.location }).first(where: { $0.range.location >= (findMatchIndex > 0 ? findMatchIndex - 1 : 0) }) {
            let range = match.range
            let newContent = SearchEngine.replace(doc.text, pattern: searchText, replacement: replaceText, options: searchOptions)
            tabStore.selectedDocument?.text = newContent
            findMatchIndex += 1
        }
    }
    
    private func replaceAll() {
        guard let doc = tabStore.selectedDocument, !searchText.isEmpty else { return }
        let newContent = SearchEngine.replace(doc.text, pattern: searchText, replacement: replaceText, options: searchOptions)
        tabStore.selectedDocument?.text = newContent
    }
    
    private func setupMenuBar() {
        let menu = NSMenu()
        
        // App menu
        let appMenu = NSMenuItem(title: "Hexpad", action: nil, keyEquivalent: "")
        let aboutMenu = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let hideMenu = NSMenuItem(title: "Hide Hexpad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quitMenu = NSMenuItem(title: "Quit Hexpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        let appSubMenu = NSMenu()
        appSubMenu.addItem(aboutMenu)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(hideMenu)
        appSubMenu.addItem(.separator())
        appSubMenu.addItem(quitMenu)
        
        appMenu.submenu = appSubMenu
        menu.addItem(appMenu)
        
        // File menu
        let fileMenu = NSMenu(title: "File")
        let newFile = NSMenuItem(title: "New", action: #selector(newFileAction), keyEquivalent: "n")
        let openFile = NSMenuItem(title: "Open...", action: #selector(openFileAction), keyEquivalent: "o")
        let saveFile = NSMenuItem(title: "Save", action: #selector(saveFileAction), keyEquivalent: "s")
        let saveAsFile = NSMenuItem(title: "Save As...", action: #selector(saveAsFileAction), keyEquivalent: "S")
        let closeTab = NSMenuItem(title: "Close", action: #selector(closeTabAction), keyEquivalent: "w")
        let closeAllTabs = NSMenuItem(title: "Close All", action: #selector(closeAllTabsAction), keyEquivalent: "W")
        
        fileMenu.addItem(newFile)
        fileMenu.addItem(openFile)
        fileMenu.addItem(saveFile)
        fileMenu.addItem(saveAsFile)
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeTab)
        fileMenu.addItem(closeAllTabs)
        
        menu.addItem(NSMenuItem(title: "File", submenu: fileMenu))
        
        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: #selector(NSResponder.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(NSResponder.redo(_:)), keyEquivalent: "Z")
        let cut = NSMenuItem(title: "Cut", action: #selector(NSResponder.cut(_:)), keyEquivalent: "x")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSResponder.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSResponder.paste(_:)), keyEquivalent: "v")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let find = NSMenuItem(title: "Find...", action: #selector(toggleFindBar), keyEquivalent: "f")
        let replace = NSMenuItem(title: "Replace...", action: #selector(toggleFindBar), keyEquivalent: "g")
        
        editMenu.addItem(undo)
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(cut)
        editMenu.addItem(copy)
        editMenu.addItem(paste)
        editMenu.addItem(selectAll)
        editMenu.addItem(.separator())
        editMenu.addItem(find)
        editMenu.addItem(replace)
        
        menu.addItem(NSMenuItem(title: "Edit", submenu: editMenu))
        
        // View menu
        let viewMenu = NSMenu(title: "View")
        let toggleFind = NSMenuItem(title: "Find & Replace", action: #selector(toggleFindBar), keyEquivalent: "f")
        let increaseFont = NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSize), keyEquivalent: "+")
        let decreaseFont = NSMenuItem(title: "Decrease Font Size", action: #selector(decreaseFontSize), keyEquivalent: "-")
        
        viewMenu.addItem(toggleFind)
        viewMenu.addItem(.separator())
        viewMenu.addItem(increaseFont)
        viewMenu.addItem(decreaseFont)
        
        menu.addItem(NSMenuItem(title: "View", submenu: viewMenu))
        
        // Encoding menu
        let encodingMenu = NSMenu(title: "Encoding")
        let utf8 = NSMenuItem(title: "UTF-8", action: #selector(setEncodingUTF8), keyEquivalent: "")
        let utf16le = NSMenuItem(title: "UTF-16 LE", action: #selector(setEncodingUTF16LE), keyEquivalent: "")
        let utf16be = NSMenuItem(title: "UTF-16 BE", action: #selector(setEncodingUTF16BE), keyEquivalent: "")
        
        encodingMenu.addItem(utf8)
        encodingMenu.addItem(utf16le)
        encodingMenu.addItem(utf16be)
        
        menu.addItem(NSMenuItem(title: "Encoding", submenu: encodingMenu))
        
        // Language menu
        let languageMenu = NSMenu(title: "Language")
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.rawValue, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.tag = lang.hashValue
            languageMenu.addItem(item)
        }
        
        menu.addItem(NSMenuItem(title: "Language", submenu: languageMenu))
        
        // Window menu
        let windowMenu = NSMenu(title: "Window")
        let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.minimize(_:)), keyEquivalent: "m")
        let zoom = NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        let fullscreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        
        windowMenu.addItem(minimize)
        windowMenu.addItem(zoom)
        windowMenu.addItem(.separator())
        windowMenu.addItem(fullscreen)
        
        menu.addItem(NSMenuItem(title: "Window", submenu: windowMenu))
        
        // Help menu
        let helpMenu = NSMenu(title: "Help")
        let about = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        helpMenu.addItem(about)
        
        menu.addItem(NSMenuItem(title: "Help", submenu: helpMenu))
        
        NSApplication.shared.menu = menu
    }
    
    // MARK: - Actions
    
    @objc private func newFileAction() {
        let doc = DocumentModel(text: "", filePath: nil)
        tabStore.addDocument(doc)
    }
    
    @objc private func openFileAction() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let encoding = EncodingDetective.detect(data)
                let text = String(data: data, encoding: String.Encoding(rawValue: EncodingDetective.nsEncoding(from: encoding))) ?? ""
                let lang = Language.fromFileName(url.lastPathComponent)
                let doc = DocumentModel(text: text, filePath: url, encoding: encoding)
                doc._language = lang.rawValue
                tabStore.addDocument(doc)
            } catch {
                showError("Failed to open file: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func saveFileAction() {
        guard let doc = tabStore.selectedDocument else { return }
        do {
            if doc.isUntitled {
                saveAsFileAction()
            } else {
                try doc.save()
                doc.setModified(false)
            }
        } catch {
            showError("Failed to save file: \(error.localizedDescription)")
        }
    }
    
    @objc private func saveAsFileAction() {
        let panel = NSSavePanel()
        panel.title = "Save File"
        panel.nameFieldStringValue = tabStore.selectedDocument?.name ?? "Untitled"
        
        if panel.runModal() == .OK, let url = panel.url {
            guard let doc = tabStore.selectedDocument else { return }
            do {
                try doc.saveAs(to: url)
            } catch {
                showError("Failed to save file: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func closeTabAction() {
        if tabStore.count > 0 {
            tabStore.removeDocument(at: tabStore.selectedIndex)
        }
    }
    
    @objc private func closeAllTabsAction() {
        tabStore.closeAll()
    }
    
    @objc private func toggleFindBar() {
        showFindBar.toggle()
    }
    
    @objc private func increaseFontSize() {
        // Font size adjustment would be handled by the editor view
    }
    
    @objc private func decreaseFontSize() {
        // Font size adjustment would be handled by the editor view
    }
    
    @objc private func setEncodingUTF8() {
        tabStore.selectedDocument?._encoding = "UTF-8"
    }
    
    @objc private func setEncodingUTF16LE() {
        tabStore.selectedDocument?._encoding = "UTF-16LE"
    }
    
    @objc private func setEncodingUTF16BE() {
        tabStore.selectedDocument?._encoding = "UTF-16BE"
    }
    
    @objc private func setLanguage(_ sender: NSMenuItem) {
        let lang = Language.allCases[sender.tag]
        tabStore.selectedDocument?._language = lang.rawValue
    }
    
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
