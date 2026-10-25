import AppKit
import HexpadKit

class MainWindowController: NSViewController {
    
    let tabStore = TabStore()
    private var mainWindow: MainWindow?
    var recentFilesManager: RecentFilesManager?
    
    // Subviews
    private var tabBarView: TabBarView?
    private var editorContainer: EditorContainer?
    private var statusBar: StatusBar?
    private var findBar: FindBar?
    
    // MARK: - Init
    
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    init(window: MainWindow) {
        self.mainWindow = window
        super.init(nibName: nil, bundle: nil)
    }
    
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        setupUI()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addNewTab()
        setupNotificationObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabCloseRequested(_:)), name: NSNotification.Name("TabCloseRequested"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDocumentModified(_:)), name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
    }
    
    @objc private func handleTabCloseRequested(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let index = userInfo["index"] as? Int else { return }
        closeTabAtIndex(index)
    }
    
    @objc private func handleDocumentModified(_ notification: Notification) {
        refreshTabBar()
        updateStatusBar()
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        
        let tabBar = TabBarView(tabStore: tabStore)
        view.addSubview(tabBar)
        tabBarView = tabBar
        
        let editor = EditorContainer()
        view.addSubview(editor)
        editorContainer = editor
        
        let status = StatusBar()
        view.addSubview(status)
        statusBar = status
        
        let find = FindBar()
        view.addSubview(find)
        findBar = find
        find.tabStoreRef = tabStore
        find.editorRef = editor
        find.setupObservers()
        
        editor.textView.delegate = self
        
        if let ruler = editor.ruler as? LineNumberGutter {
            ruler.setClickHandler { [weak self] charIndex in
                self?.selectCharacter(charIndex)
            }
        }
        
        updateLayout()
    }
    
    private func updateLayout() {
        guard let tabBar = tabBarView,
              let editor = editorContainer,
              let status = statusBar else { return }
        
        let tabBarHeight: CGFloat = 32
        let statusHeight: CGFloat = 22
        let findHeight: CGFloat = 36
        
        tabBar.frame = NSRect(x: 0, y: view.bounds.height - tabBarHeight, width: view.bounds.width, height: tabBarHeight)
        
        let findVisible = findBar?.isVisible ?? false
        let editorTop = view.bounds.height - tabBarHeight - (findVisible ? findHeight : 0)
        let editorHeight = editorTop - statusHeight
        
        editor.frame = NSRect(x: 0, y: statusHeight, width: view.bounds.width, height: max(editorHeight, 100))
        
        status.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: statusHeight)
        
        if findVisible {
            findBar?.frame = NSRect(x: 0, y: editorTop, width: view.bounds.width, height: findHeight)
        }
    }
    
    // MARK: - Tab Management
    
    func addNewTab() {
        let doc = DocumentModel(text: "")
        tabStore.addDocument(doc)
        refreshTabBar()
        updateEditor()
        updateStatusBar()
    }
    
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Filter to text-ish files
        panel.allowedContentTypes = [.plainText, .sourceCode, .script]
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(atURL: url)
    }
    
    /// Open a file from a path string (used by Open Recent menu). No-op if file doesn't exist.
    func openFile(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        openFile(atURL: url)
    }
    
    private func openFile(atURL url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let encoding = EncodingDetective.detect(data)
            let nsEnc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: encoding))
            let text = String(data: data, encoding: nsEnc) ?? ""
            let extLang = Language.fromFileName(url.lastPathComponent)
            
            var finalLang = extLang
            if extLang == .plain {
                // No recognized extension — trust the sniffer
                if let sniffed = ContentSniffer.sniffLanguage(data) {
                    finalLang = sniffed
                }
            } else if let sniffed = ContentSniffer.sniffLanguage(data), sniffed != extLang {
                // Extension says one language, content says another — ask the user
                finalLang = askLanguageMismatch(ext: extLang, sniffed: sniffed)
            }
            
            let doc = DocumentModel(text: text, filePath: url, encoding: encoding)
            doc.setLanguage(finalLang.rawValue)
            tabStore.addDocument(doc)
            refreshTabBar()
            updateEditor()
            updateStatusBar()
            recentFilesManager?.addRecent(url.path)
        } catch {
            showError("Failed to open file: \(error.localizedDescription)")
        }
    }
    
    private func askLanguageMismatch(ext: Language, sniffed: Language) -> Language {
        let alert = NSAlert()
        alert.messageText = "Language Mismatch"
        alert.informativeText = "This file is .\(extensionForLanguage(ext)) but its contents look like \(sniffed.rawValue). Open as which?"
        alert.addButton(withTitle: "Keep \(ext.rawValue)")
        alert.addButton(withTitle: "Open as \(sniffed.rawValue)")
        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? sniffed : ext
    }
    
    private func extensionForLanguage(_ lang: Language) -> String {
        switch lang {
        case .json: return "json"
        case .python: return "py"
        case .javascript: return "js"
        case .typescript: return "ts"
        case .html: return "html"
        case .css: return "css"
        case .markdown: return "md"
        case .xml: return "xml"
        case .shell: return "sh"
        case .swift: return "swift"
        case .plain: return "txt"
        }
    }
    
    func saveFile() {
        guard let doc = tabStore.selectedDocument else { return }
        do {
            if doc.isUntitled {
                saveAsFile()
            } else {
                try doc.save()
                doc.setModified(false)
                NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
                refreshTabBar()
                updateStatusBar()
            }
        } catch {
            showError("Failed to save file: \(error.localizedDescription)")
        }
    }
    
    func saveAsFile() {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.nameFieldStringValue = tabStore.selectedDocument?.name ?? "Untitled"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        guard let doc = tabStore.selectedDocument else { return }
        let oldPath = doc.filePath?.path
        do {
            try doc.saveAs(to: url)
            recentFilesManager?.replaceRecent(oldPath: oldPath, newPath: url.path)
            NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
            refreshTabBar()
            updateStatusBar()
        } catch {
            showError("Failed to save file: \(error.localizedDescription)")
        }
    }
    
    func closeSelectedTab() {
        guard tabStore.count > 0 else { return }
        guard let doc = tabStore.selectedDocument, !doc.unsavedChanges else {
            closeTabAtIndex(tabStore.selectedIndex)
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Save changes to \(doc.name)?"
        alert.informativeText = "You have unsaved changes to this document."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        
        alert.beginSheetModal(for: mainWindow ?? NSApplication.shared.windows.first ?? NSWindow()) { response in
            DispatchQueue.main.async {
                switch response {
                case .alertFirstButtonReturn: // Save
                    self.saveDocument(doc)
                    self.closeTabAtIndex(self.tabStore.selectedIndex)
                case .alertSecondButtonReturn: // Don't Save
                    self.closeTabAtIndex(self.tabStore.selectedIndex)
                case .alertThirdButtonReturn: // Cancel
                    break
                default:
                    break
                }
            }
        }
    }
    
    private func saveDocument(_ doc: DocumentModel) {
        do {
            if doc.isUntitled {
                // For untitled docs, try to save in place if path exists
                try doc.save()
            } else {
                try doc.save()
            }
            doc.setModified(false)
            NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
            refreshTabBar()
            updateStatusBar()
        } catch {
            showError("Failed to save file: \(error.localizedDescription)")
        }
    }
    
    func closeTabAtIndex(_ index: Int) {
        guard tabStore.count > 0 else { return }
        tabStore.removeDocument(at: index)
        refreshTabBar()
        updateEditor()
        updateStatusBar()
        
        if tabStore.count == 0 {
            addNewTab()
        }
    }
    
    func closeAllTabs() {
        tabStore.closeAll()
        refreshTabBar()
        updateEditor()
        updateStatusBar()
        addNewTab()
    }
    
    func refreshTabBar() {
        tabBarView?.reloadTabs()
    }
    
    func updateEditor() {
        guard let editor = editorContainer else { return }
        if let doc = tabStore.selectedDocument {
            let selRange = editor.textView.selectedRange
            editor.textView.string = doc.text
            editor.textView.selectedRange = selRange
            applySyntaxHighlighting(to: editor, for: doc)
        } else {
            editor.textView.string = ""
        }
        updateStatusBar()
    }
    
    private func applySyntaxHighlighting(to editor: EditorContainer, for doc: DocumentModel) {
        let textStorage = editor.textView.textStorage
        guard let textStorage else { return }
        
        let text = doc.text
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        
        // Plain Text = no highlighting, clear attributes
        guard let langStr = Language.allCases.first(where: { $0.rawValue == doc.language }) else {
            textStorage.beginEditing()
            textStorage.removeAttribute(.foregroundColor, range: fullRange)
            textStorage.removeAttribute(.backgroundColor, range: fullRange)
            textStorage.endEditing()
            return
        }
        
        let tokens = SyntaxTokenizer.tokenize(text, language: langStr)
        let theme = HexpadTheme.dark.theme
        
        textStorage.beginEditing()
        // Reset to default foreground color and monospaced font
        textStorage.setAttributes([
            .foregroundColor: theme.foreground,
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ], range: fullRange)
        
        // Apply per-token colors
        for token in tokens {
            guard token.type != .whitespace, token.type != .plain else { continue }
            let color = SyntaxTokenizer.color(for: token.type, theme: theme)
            textStorage.setAttributes([.foregroundColor: color], range: token.range)
        }
        textStorage.endEditing()
    }
    
    func updateStatusBar() {
        guard let status = statusBar, let editor = editorContainer else { return }
        let doc = tabStore.selectedDocument
        status.update(with: doc, textView: editor.textView)
    }
    
    // MARK: - Find
    
    func toggleFindBar() {
        guard let find = findBar else { return }
        if find.isVisible {
            find.hide()
        } else {
            find.show()
            // Pre-populate if text selected
            if let editor = editorContainer, editor.textView.selectedRange.length > 0 {
                let selected = (editor.textView.string as NSString).substring(with: editor.textView.selectedRange)
                find.searchField.stringValue = selected
                find.performFind()
            }
        }
        updateLayout()
    }
    
    func findNext() {
        findBar?.findNext()
    }
    
    func findPrevious() {
        findBar?.findPrevious()
    }
    
    // MARK: - View
    
    func toggleWordWrap() {
        editorContainer?.textView.isHorizontallyResizable.toggle()
    }
    
    func zoomIn() {
        guard let font = editorContainer?.textView.font else { return }
        editorContainer?.textView.font = NSFont.monospacedSystemFont(ofSize: font.pointSize + 1, weight: .regular)
    }
    
    func zoomOut() {
        guard let font = editorContainer?.textView.font, font.pointSize > 8 else { return }
        editorContainer?.textView.font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
    }
    
    func resetZoom() {
        editorContainer?.textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }
    
    // MARK: - Encoding
    
    func setEncoding(_ encoding: String) {
        if let doc = tabStore.selectedDocument { doc.setEncoding(encoding) }
        updateStatusBar()
    }
    
    func setLanguage(_ lang: Language) {
        if let doc = tabStore.selectedDocument { doc.setLanguage(lang.rawValue) }
        updateEditor()
    }
    
    // MARK: - Session
    
    func saveSession() {
        try? SessionStore.save(tabStore)
    }
    
    // MARK: - Error
    
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
    
    // MARK: - Gutter Click

    /// Places the caret at a character index resolved by the gutter's layout
    /// geometry — no pixel ÷ magic-number line math.
    private func selectCharacter(_ charIndex: Int) {
        guard let editor = editorContainer else { return }
        let clamped = min(max(0, charIndex), (editor.textView.string as NSString).length)
        let selRange = NSRange(location: clamped, length: 0)
        editor.textView.setSelectedRange(selRange)
        editor.textView.scrollRangeToVisible(selRange)
    }
}

// MARK: - NSTextViewDelegate

extension MainWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let doc = tabStore.selectedDocument, let editor = editorContainer else { return }
        doc.text = editor.textView.string
        doc.setModified(true)
        refreshTabBar()
        updateStatusBar()
        applySyntaxHighlighting(to: editor, for: doc)
    }
    
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertTab(_:)) {
            textView.insertText("    ", replacementRange: textView.selectedRange)
            return true
        }
        if selector == #selector(insertBacktab(_:)) {
            let range = textView.selectedRange
            if range.length == 0 {
                let checkRange = NSMakeRange(max(0, range.location - 4), 4)
                let text = textView.string as NSString
                if text.substring(with: checkRange) == "    " {
                    textView.deleteBackward(nil)
                    textView.deleteBackward(nil)
                    textView.deleteBackward(nil)
                    textView.deleteBackward(nil)
                }
            }
            return true
        }
        return false
    }
}
