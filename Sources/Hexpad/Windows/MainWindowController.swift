import AppKit
import HexpadKit

class MainWindowController: NSViewController {
    
    let tabStore = TabStore()
    private var mainWindow: MainWindow?
    
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
        
        editor.textView.delegate = self
        
        if let ruler = editor.ruler as? LineNumberGutter {
            ruler.setClickHandler { [weak self] point in
                self?.handleGutterClick(point)
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
        
        do {
            let data = try Data(contentsOf: url)
            let encoding = EncodingDetective.detect(data)
            let nsEnc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: encoding))
            let text = String(data: data, encoding: nsEnc) ?? ""
            let lang = Language.fromFileName(url.lastPathComponent)
            
            let doc = DocumentModel(text: text, filePath: url, encoding: encoding)
            doc.setLanguage(lang.rawValue)
            tabStore.addDocument(doc)
            refreshTabBar()
            updateEditor()
            updateStatusBar()
        } catch {
            showError("Failed to open file: \(error.localizedDescription)")
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
        do {
            try doc.saveAs(to: url)
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
            editor.textView.string = doc.text
            let selRange = editor.textView.selectedRange
            editor.textView.selectedRange = selRange
            applySyntaxHighlighting(to: editor, for: doc)
        } else {
            editor.textView.string = ""
        }
        updateStatusBar()
    }
    
    private func applySyntaxHighlighting(to editor: EditorContainer, for doc: DocumentModel) {
        guard let langStr = Language.allCases.first(where: { $0.rawValue == doc.language }) else {
            let whole = NSRange(location: 0, length: editor.textView.string.count)
            editor.textView.textStorage?.removeAttribute(.foregroundColor, range: whole)
            editor.textView.textStorage?.removeAttribute(.backgroundColor, range: whole)
            return
        }
        
        let tokens = SyntaxTokenizer.tokenize(doc.text, language: langStr)
        let theme = HexpadTheme.dark.theme
        
        let fullRange = NSRange(location: 0, length: doc.text.count)
        editor.textView.textStorage?.beginEditing()
        editor.textView.textStorage?.setAttributes([.foregroundColor: theme.foreground, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)], range: fullRange)
        
        for token in tokens {
            guard token.type != .whitespace, token.type != .plain else { continue }
            let color = SyntaxTokenizer.color(for: token.type, theme: theme)
            editor.textView.textStorage?.setAttributes([.foregroundColor: color], range: token.range)
        }
        editor.textView.textStorage?.endEditing()
    }
    
    func updateStatusBar() {
        guard let status = statusBar, let editor = editorContainer else { return }
        let doc = tabStore.selectedDocument
        status.update(with: doc, textView: editor.textView)
    }
    
    // MARK: - Find
    
    func toggleFindBar() {
        guard let find = findBar else { return }
        find.isVisible.toggle()
        if find.isVisible {
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
    
    private func handleGutterClick(_ point: NSPoint) {
        guard let editor = editorContainer else { return }
        let lineNum = Int(point.y / 18) + 1
        let charIndex = charIndexForLine(editor.textView, line: lineNum)
        let selRange = NSRange(location: charIndex, length: 0)
        editor.textView.setSelectedRange(selRange)
        editor.textView.scrollRangeToVisible(selRange)
    }
    
    private func charIndexForLine(_ textView: NSTextView, line: Int) -> Int {
        let text = textView.string
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for i in 0..<min(line, lines.count) {
            if i < line - 1 {
                offset += lines[i].count + 1
            }
        }
        return offset
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
