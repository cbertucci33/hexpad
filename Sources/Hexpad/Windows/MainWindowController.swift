import AppKit
import HexpadKit

class MainWindowController: NSViewController {
    
    let tabStore = TabStore()
    private var mainWindow: MainWindow?
    var recentFilesManager: RecentFilesManager?

    /// Menu/keybinding layer for the editor commands. The registry itself is
    /// Kit-owned; this controller only resolves and applies its commands to the
    /// selected document.
    private let commandRegistry = CommandRegistry.default

    /// The text view backing the selected document. Exposed for menu
    /// validation/action tests in the app test bundle.
    var editorTextView: NSTextView? { editorContainer?.textView }
    
    // Subviews
    private var tabBarView: TabBarView?
    private var tabScrollView: NSScrollView?
    private var editorContainer: EditorContainer?
    /// Document whose buffer/undo stack is currently loaded in the editor.
    private weak var editorBoundDoc: DocumentModel?
    private var statusBar: StatusBar?
    private var findBar: FindBar?
    /// Block-based observer token for NSTextView selection changes; drives the
    /// status bar's live Ln/Col display.
    private var textSelectionObserver: NSObjectProtocol?

    // Syntax highlighting pipeline: one sparse token cache for the selected
    // document, plus the last attributed range, so a keystroke or scroll never
    // resets the whole buffer.
    private let syntaxStore = TokenStore(language: .plain)
    private var lastHighlightedRange = NSRange(location: 0, length: 0)
    private weak var highlightedDoc: DocumentModel?
    private var docThemeNames: [UUID: String] = [:]
    private var pendingEditRange: NSRange?
    
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
        startFileWatching()
    }

    deinit {
        stopFileWatching()
        NotificationCenter.default.removeObserver(self)
        if let observer = textSelectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleTabCloseRequested(_:)), name: NSNotification.Name("TabCloseRequested"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDocumentModified(_:)), name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
        // Programmatic edits (find/replace, line ops, reloads) mutate the shared
        // storage directly, so they never reach the NSTextView delegate. Watch
        // the model to refresh highlighting, dirty dots, and the status bar.
        NotificationCenter.default.addObserver(self, selector: #selector(handleModelTextChange(_:)), name: DocumentModel.textDidChangeNotification, object: nil)
        // Any close path (menu toggle, Escape, × button) must restore the
        // editor to full height. Previously nothing observed this notice.
        NotificationCenter.default.addObserver(self, selector: #selector(handleFindBarClosed(_:)), name: NSNotification.Name("FindBarClosed"), object: nil)
        // Live Ln/Col: caret moves (arrows, clicks, typing, find navigation,
        // programmatic selection) all post this notification from the text view.
        textSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSTextViewDidChangeSelectionNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusBar()
        }
    }

    @objc private func handleFindBarClosed(_ notification: Notification) {
        updateLayout()
        if let editor = editorContainer {
            view.window?.makeFirstResponder(editor.textView)
        }
    }
    
    @objc private func handleTabCloseRequested(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let index = userInfo["index"] as? Int else { return }
        guard tabStore.count > 0, index >= 0, index < tabStore.count else { return }
        let doc = tabStore.documents[index]
        
        if doc.unsavedChanges {
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
                        // Untitled docs need a save panel; doc.save() throws
                        // noFilePath for them. Only close once the save succeeded
                        // (or the user actually picked a destination).
                        if doc.isUntitled {
                            self.saveAsAndClose(doc)
                        } else {
                            self.saveDocument(doc)
                            self.closeTabAtIndex(index)
                        }
                    case .alertSecondButtonReturn: // Don't Save
                        self.closeTabAtIndex(index)
                    case .alertThirdButtonReturn: // Cancel
                        break
                    default:
                        break
                    }
                }
            }
        } else {
            closeTabAtIndex(index)
        }
    }
    
    @objc private func handleDocumentModified(_ notification: Notification) {
        refreshTabBar()
        updateStatusBar()
        updateWindowTitle()
    }

    @objc private func handleModelTextChange(_ notification: Notification) {
        guard let doc = notification.object as? DocumentModel else { return }

        // Typing posts this notice from textDidChange after it has already
        // incrementally re-highlighted and refreshed the chrome. Handling it
        // again here would tokenize the same edit twice and refresh the tab
        // bar/status bar twice per keystroke. Other observers (FindBar gets
        // the original notification directly) still see the change.
        if notification.userInfo?["editedRange"] != nil {
            return
        }

        if doc === tabStore.selectedDocument, let editor = editorContainer {
            // Programmatic edits (find/replace, line ops, reloads) can replace
            // the whole buffer. Forget the theme record so the next pass
            // re-attributes the full storage, not just the visible band.
            docThemeNames.removeValue(forKey: doc.id)
            applySyntaxHighlighting(to: editor, for: doc, forceReset: true)
        }
        // Tab dirty dots, the status bar, and FindBar counts all key off this.
        NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        
        let tabBar = TabBarView(tabStore: tabStore)
        // Tabs scroll horizontally instead of clipping once they exceed the
        // window; the bar itself grows to its content width.
        let tabScroll = NSScrollView()
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.hasVerticalScroller = false
        tabScroll.drawsBackground = false
        tabScroll.borderType = .noBorder
        tabScroll.documentView = tabBar
        view.addSubview(tabScroll)
        tabScrollView = tabScroll
        tabBarView = tabBar
        
        let editor = EditorContainer()
        view.addSubview(editor)
        editorContainer = editor
        
        let status = StatusBar()
        view.addSubview(status)
        statusBar = status

        // Width-following masks so interim resizes stay sane even before
        // viewDidLayout runs the authoritative pass.
        tabBar.autoresizingMask = [.width, .height]
        tabScroll.autoresizingMask = [.width, .minYMargin]
        editor.autoresizingMask = [.width, .height]
        status.autoresizingMask = [.width, .maxYMargin]
        
        let find = FindBar()
        view.addSubview(find)
        findBar = find
        find.tabStoreRef = tabStore
        find.editorRef = editor
        find.setupObservers()
        
        editor.textView.delegate = self
        editor.onViewportChange = { [weak self] in
            self?.refreshVisibleHighlighting()
        }
        editor.onAppearanceChange = { [weak self] in
            self?.handleAppearanceChange()
        }
        
        if let ruler = editor.ruler as? LineNumberGutter {
            ruler.setClickHandler { [weak self] charIndex, anchorCharIndex in
                self?.selectCharacter(charIndex, anchorCharIndex: anchorCharIndex)
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

        // The find bar always occupies its slot when visible; hidden state is
        // expressed with isHidden, so a resize never leaves a stale rect for a
        // bar that would then reappear in the wrong place.
        let findVisible = findBar?.isVisible ?? false
        let findHeight = findBar?.preferredHeight(for: view.bounds.width) ?? 36
        let topInset = tabBarHeight + (findVisible ? findHeight : 0)
        let height = view.bounds.height

        tabScrollView?.frame = NSRect(x: 0, y: max(0, height - tabBarHeight), width: view.bounds.width, height: tabBarHeight)
        tabBar.frame.size.height = tabBarHeight
        tabBar.fitWidthToClip()
        findBar?.frame = NSRect(x: 0,
                                y: max(statusHeight, height - topInset),
                                width: view.bounds.width,
                                height: findHeight)

        let editorTop = height - topInset
        let editorHeight = max(editorTop - statusHeight, 100)
        editor.frame = NSRect(x: 0, y: statusHeight, width: view.bounds.width, height: editorHeight)

        status.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: statusHeight)
    }

    /// Resizing the window used to leave every subview at its launch frame
    /// (all autoresizingMask 0, updateLayout only ran on toggle), so the tab bar
    /// and find bar ended up above the visible content area.
    override func viewDidLayout() {
        super.viewDidLayout()
        updateLayout()
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
    
    /// Open a file and reveal a byte/char range (Find in Files jump target).
    func openFileAt(url: URL, revealing range: NSRange) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        openFile(atURL: url)
        guard let editor = editorContainer else { return }
        let length = (editor.textView.string as NSString).length
        guard range.location <= length else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, length - range.location))
        editor.textView.setSelectedRange(clamped)
        editor.textView.scrollRangeToVisible(clamped)
        view.window?.makeFirstResponder(editor.textView)
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
        case .c: return "c"
        case .cpp: return "cpp"
        case .csharp: return "cs"
        case .java: return "java"
        case .kotlin: return "kt"
        case .ruby: return "rb"
        case .go: return "go"
        case .rust: return "rs"
        case .php: return "php"
        case .sql: return "sql"
        case .yaml: return "yaml"
        case .toml: return "toml"
        case .ini: return "ini"
        case .lua: return "lua"
        case .r: return "r"
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
        guard let doc = tabStore.selectedDocument else { return }
        
        if doc.unsavedChanges {
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
                        // Untitled docs need a save panel; doc.save() throws
                        // noFilePath for them. Only close once the save succeeded
                        // (or the user actually picked a destination).
                        if doc.isUntitled {
                            self.saveAsAndClose(doc)
                        } else {
                            self.saveDocument(doc)
                            self.closeTabAtIndex(self.tabStore.selectedIndex)
                        }
                    case .alertSecondButtonReturn: // Don't Save
                        self.closeTabAtIndex(self.tabStore.selectedIndex)
                    case .alertThirdButtonReturn: // Cancel
                        break
                    default:
                        break
                    }
                }
            }
        } else {
            closeTabAtIndex(tabStore.selectedIndex)
        }
    }

    /// Save-as flow used by the close prompt for untitled docs: close the tab
    /// only when the user picked a destination and the write succeeded.
    ///
    /// Returns false when the panel was cancelled or the write failed, so a
    /// multi-tab sweep can halt instead of silently moving on.
    @discardableResult
    private func saveAsAndClose(_ doc: DocumentModel) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.nameFieldStringValue = doc.name

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let oldPath = doc.filePath?.path
            try doc.saveAs(to: url)
            recentFilesManager?.replaceRecent(oldPath: oldPath, newPath: url.path)
            NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
            refreshTabBar()
            updateStatusBar()
            // Close the document we just saved, not whatever tab happens to
            // be selected now (the save panel can change focus/selection).
            if let index = tabStore.documents.firstIndex(where: { $0 === doc }) {
                closeTabAtIndex(index)
            }
            return true
        } catch {
            showError("Failed to save file: \(error.localizedDescription)")
            return false
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
        guard tabStore.count > 0 else {
            addNewTab()
            return
        }
        
        // Walk tabs back-to-front so removing a higher index never shifts a
        // lower one into an already-processed slot. Dirty docs get the same
        // save prompt as a single close; Cancel stops the sweep and leaves the
        // remaining tabs open.
        var index = tabStore.count - 1
        var shouldContinueClosing = true
        
        func closeNextTab() {
            guard shouldContinueClosing, index >= 0, index < tabStore.count else { return }
            let doc = tabStore.documents[index]
            
            if doc.unsavedChanges {
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
                            // Untitled docs need a save panel; doc.save() throws
                            // noFilePath for them. Only close once the save succeeded
                            // (or the user actually picked a destination). A
                            // cancelled panel must stop the whole sweep.
                            if doc.isUntitled {
                                guard self.saveAsAndClose(doc) else {
                                    shouldContinueClosing = false
                                    return
                                }
                            } else {
                                self.saveDocument(doc)
                                self.closeTabAtIndex(index)
                            }
                            index -= 1
                            closeNextTab()
                        case .alertSecondButtonReturn: // Don't Save
                            self.closeTabAtIndex(index)
                            index -= 1
                            closeNextTab()
                        case .alertThirdButtonReturn: // Cancel
                            shouldContinueClosing = false
                        default:
                            shouldContinueClosing = false
                        }
                    }
                }
            } else {
                closeTabAtIndex(index)
                index -= 1
                closeNextTab()
            }
        }
        
        closeNextTab()
    }

    /// Selects a tab by index and refreshes the editor/chrome. All menu and
    /// keyboard tab navigation funnels through here so undo stacks and
    /// per-document editor state are rebound exactly like a tab-bar click.
    func selectTab(at index: Int) {
        guard index >= 0, index < tabStore.count else { return }
        guard index != tabStore.selectedIndex else { return }
        tabStore.selectDocument(at: index)
        refreshTabBar()
        updateEditor()
        updateStatusBar()
    }

    /// Wraps forward through the open tabs. Disabled with fewer than two tabs
    /// by menu validation, but still safe to call directly.
    func selectNextTab() {
        guard tabStore.count > 1 else { return }
        selectTab(at: (tabStore.selectedIndex + 1) % tabStore.count)
    }

    /// Wraps backward through the open tabs.
    func selectPreviousTab() {
        guard tabStore.count > 1 else { return }
        selectTab(at: (tabStore.selectedIndex - 1 + tabStore.count) % tabStore.count)
    }

    @objc func selectNextTab(_ sender: Any?) {
        selectNextTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        selectPreviousTab()
    }

    /// Handles the Cmd+1..9 menu items; the item tag holds the 1-based tab
    /// number so one action covers all nine shortcuts.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        selectTab(at: sender.tag - 1)
    }
    
    func refreshTabBar() {
        tabBarView?.reloadTabs()
    }
    
    func updateEditor() {
        guard let editor = editorContainer else { return }
        // There is nothing to flush: the editor's text view shares the
        // document's storage, so the model already holds every keystroke.
        if let doc = tabStore.selectedDocument {
            editorBoundDoc = doc
            // Per-document undo stacks: switching tabs must not wipe undo.
            // NSTextView.undoManager is get-only (delegate-provided); rebind
            // the layout manager so typing registers on this doc's stack.
            let selRange = editor.textView.selectedRange
            editor.bind(to: doc)
            let maxLoc = (doc.text as NSString).length
            editor.textView.selectedRange = NSRange(location: min(selRange.location, maxLoc),
                                                    length: min(selRange.length,
                                                                max(0, maxLoc - min(selRange.location, maxLoc))))
            applySyntaxHighlighting(to: editor, for: doc, forceReset: true)
        } else {
            editorBoundDoc = nil
            highlightedDoc = nil
            syntaxStore.reset()
            lastHighlightedRange = NSRange(location: 0, length: 0)
            editor.bind(to: nil)
            editor.textView.selectedRange = NSRange(location: 0, length: 0)
        }
        updateStatusBar()
        updateWindowTitle()
    }
    
    // MARK: - Syntax highlighting

    /// Highlights only the visible line band (plus a margin). Typing passes the
    /// edited range so the token cache re-tokenizes that line band only;
    /// programmatic edits force a viewport rebuild.
    private func applySyntaxHighlighting(to editor: EditorContainer,
                                         for doc: DocumentModel,
                                         editedRange: NSRange? = nil,
                                         forceReset: Bool = false) {
        let textStorage = editor.textView.textStorage
        guard let textStorage else { return }

        let text = doc.text
        let textLength = (text as NSString).length
        let theme = theme(for: editor)
        editor.apply(theme: theme)

        let docChanged = highlightedDoc !== doc
        if docChanged {
            highlightedDoc = doc
            lastHighlightedRange = NSRange(location: 0, length: 0)
        }

        // A cold document or an appearance change cannot know which characters
        // still carry old theme colours, so reset them once. Switching to an
        // already-themed tab and the per-keystroke path never do this.
        var needsReset = forceReset || docChanged
        if docThemeNames[doc.id] != theme.name {
            textStorage.beginEditing()
            textStorage.setAttributes([
                .font: editor.bodyFont,
                .foregroundColor: theme.foreground
            ], range: NSRange(location: 0, length: textLength))
            textStorage.endEditing()
            docThemeNames[doc.id] = theme.name
            lastHighlightedRange = NSRange(location: 0, length: 0)
            needsReset = true
        }

        // Plain Text = no token colors, but keep the editor's monospaced font:
        // an unattributed shared storage would render as Helvetica.
        guard let language = Language(rawValue: doc.language),
              language != .plain else {
            clearHighlighting(in: textStorage, range: lastHighlightedRange,
                              theme: theme, font: editor.bodyFont, textLength: textLength)
            syntaxStore.reset(language: .plain)
            return
        }

        if syntaxStore.language != language {
            syntaxStore.reset(language: language)
            clearHighlighting(in: textStorage, range: lastHighlightedRange,
                              theme: theme, font: editor.bodyFont, textLength: textLength)
        } else if needsReset || docChanged {
            syntaxStore.reset(language: language)
        }

        if let editedRange {
            syntaxStore.update(text: text, language: language, editedRange: editedRange)
        } else if syntaxStore.textLength != textLength {
            syntaxStore.reset(language: language)
        }

        let visibleRange = editor.visibleCharacterRange()
        let target = syntaxStore.ensureTokens(for: text, range: visibleRange)

        textStorage.beginEditing()
        // Reset the previous viewport before painting the new one so stale
        // colours cannot survive outside the current band.
        if lastHighlightedRange.length > 0 {
            let previous = clipped(lastHighlightedRange, to: textLength)
            if previous.length > 0 {
                textStorage.setAttributes([
                    .font: editor.bodyFont,
                    .foregroundColor: theme.foreground
                ], range: previous)
            }
        }
        if target.length > 0 {
            let safeTarget = clipped(target, to: textLength)
            textStorage.setAttributes([
                .font: editor.bodyFont,
                .foregroundColor: theme.foreground
            ], range: safeTarget)

            for token in syntaxStore.tokens(in: safeTarget) {
                guard token.type != .whitespace, token.type != .plain else { continue }
                let tokenRange = clipped(token.range, to: textLength)
                guard tokenRange.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor,
                                         value: SyntaxTokenizer.color(for: token.type, theme: theme),
                                         range: tokenRange)
            }
        }
        textStorage.endEditing()
        lastHighlightedRange = target
    }

    /// Scroll/resize hook: only re-run the pipeline when the viewport leaves
    /// the band that is already highlighted.
    private func refreshVisibleHighlighting() {
        guard let editor = editorContainer,
              let doc = tabStore.selectedDocument,
              doc === editorBoundDoc else { return }

        let textLength = (doc.text as NSString).length
        let visible = clipped(editor.visibleCharacterRange(), to: textLength)
        if lastHighlightedRange.length > 0,
           visible.location >= lastHighlightedRange.location,
           NSMaxRange(visible) <= NSMaxRange(lastHighlightedRange) {
            return
        }
        applySyntaxHighlighting(to: editor, for: doc)
    }

    /// Resolves the theme from the text view's effective appearance, so System
    /// mode and the explicit Light/Dark menu both agree with what is rendered.
    private func theme(for editor: EditorContainer) -> Theme {
        HexpadTheme.forAppearance(editor.textView.effectiveAppearance)
    }

    private func handleAppearanceChange() {
        guard let editor = editorContainer else { return }
        // Every document may have been painted with the old theme; invalidate
        // their records so the next display performs one corrective reset.
        docThemeNames.removeAll()
        lastHighlightedRange = NSRange(location: 0, length: 0)
        syntaxStore.reset()
        guard let doc = tabStore.selectedDocument else { return }
        applySyntaxHighlighting(to: editor, for: doc, forceReset: true)
    }

    private func clearHighlighting(in textStorage: NSTextStorage,
                                   range: NSRange,
                                   theme: Theme,
                                   font: NSFont,
                                   textLength: Int) {
        let safe = clipped(range, to: textLength)
        guard safe.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.setAttributes([.font: font, .foregroundColor: theme.foreground], range: safe)
        textStorage.endEditing()
        lastHighlightedRange = NSRange(location: 0, length: 0)
    }

    private func clipped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let available = max(0, length - location)
        return NSRange(location: location, length: min(max(0, range.length), available))
    }
    
    func updateStatusBar() {
        guard let status = statusBar, let editor = editorContainer else { return }
        let doc = tabStore.selectedDocument
        status.update(with: doc, textView: editor.textView)
    }
    
    // MARK: - Window title / edited state
    
    /// Keeps the window title and edited flag in sync with the selected
    /// document using the AppKit document-window convention: the title is the
    /// document's filename (or "Untitled" when none), and `documentEdited` is
    /// set while the buffer has unsaved changes so the window shows the native
    /// edited indicator.
    func updateWindowTitle() {
        guard let window = mainWindow else { return }
        let doc = tabStore.selectedDocument
        window.representedURL = doc?.filePath
        window.title = doc?.name ?? "Untitled"
        window.isDocumentEdited = doc?.unsavedChanges ?? false
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
            // Focus the field: without this the editor kept first responder and
            // typing after Cmd+F landed in the document instead of the query.
            view.window?.makeFirstResponder(find.searchField)
        }
        updateLayout()
    }
    
    func findNext() {
        findBar?.findNext()
    }
    
    func findPrevious() {
        findBar?.findPrevious()
    }
    
    // MARK: - External change monitoring

    /// Watches open files for on-disk edits by other programs. Spec requires a
    /// reload path; the model had no file monitoring at all. A clean buffer
    /// reloads silently, a dirty buffer keeps its edits and flags the tab.
    private var watchTimer: Timer?
    private var seenModDates: [UUID: Date] = [:]

    private func startFileWatching() {
        stopFileWatching()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkExternalChanges()
        }
        timer.tolerance = 0.5
        watchTimer = timer
    }

    private func stopFileWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func checkExternalChanges() {
        for doc in tabStore.documents {
            guard let path = doc.filePath?.path else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            guard let modDate = attrs?[.modificationDate] as? Date else { continue }

            // First sighting records the baseline, no reload.
            guard let previous = seenModDates[doc.id] else {
                seenModDates[doc.id] = modDate
                continue
            }
            guard modDate > previous else { continue }
            seenModDates[doc.id] = modDate

            guard !doc.unsavedChanges, FileManager.default.fileExists(atPath: path) else {
                // Dirty buffer: keep the user's edits, just note the change.
                doc.setModified(true)
                continue
            }
            guard let data = try? Data(contentsOf: doc.filePath!) else { continue }
            let nsEnc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: doc.encoding))
            guard let text = String(data: data, encoding: nsEnc), text != doc.text else { continue }
            // Reload through the shared buffer: the visible editor updates
            // immediately and the reload stays undoable. reloadText also makes
            // the on-disk text the clean baseline in the same notification.
            doc.reloadText(text)
            if doc === tabStore.selectedDocument {
                updateEditor()
            }
        }
    }

    // MARK: - View
    
    func toggleWordWrap() {
        editorContainer?.textView.isHorizontallyResizable.toggle()
    }
    
    func zoomIn() {
        guard let editor = editorContainer else { return }
        editor.setBodyFont(NSFont.monospacedSystemFont(ofSize: editor.bodyFont.pointSize + 1, weight: .regular))
    }
    
    func zoomOut() {
        guard let editor = editorContainer, editor.bodyFont.pointSize > 8 else { return }
        editor.setBodyFont(NSFont.monospacedSystemFont(ofSize: editor.bodyFont.pointSize - 1, weight: .regular))
    }
    
    func resetZoom() {
        editorContainer?.setBodyFont(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }
    
    // MARK: - Encoding

    /// Encoding entries shared by the "Encode in" and "Convert to" submenus.
    /// The name resolves through `EncodingDetective.nsEncoding(from:)`, so both
    /// spellings of the UTF-16 variants stay in one place.
    static let encodingOptions: [(title: String, name: String)] = [
        ("UTF-8", "UTF-8"),
        ("UTF-16 LE", "UTF-16LE"),
        ("UTF-16 BE", "UTF-16BE"),
        ("ASCII", "ASCII"),
        ("ISO-8859-1", "ISO-8859-1"),
        ("Windows-1252", "Windows-1252")
    ]

    /// "Encode in": reinterpret the file's raw bytes with `encoding` without
    /// transcoding. The file on disk is left untouched; the buffer becomes the
    /// faithful decode of those same bytes, so the document stays clean.
    @objc func encodeIn(_ encoding: String) {
        guard let doc = tabStore.selectedDocument, doc.filePath != nil else { return }
        guard doc.redecodeFromDisk(as: encoding) else {
            showError("This file's bytes are not valid \(encoding).")
            return
        }
        updateEditor()
        refreshTabBar()
        updateStatusBar()
    }

    /// "Convert to": retarget the next save at `encoding` and mark the document
    /// dirty. The buffer is not re-decoded, so "Encode in" and "Convert to" can
    /// mark different entries at the same time.
    @objc func convertToEncoding(_ encoding: String) {
        guard let doc = tabStore.selectedDocument else { return }
        do {
            try doc.convertEncoding(to: encoding)
        } catch {
            showError("Failed to convert to \(encoding): \(error.localizedDescription)")
            return
        }
        NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
        refreshTabBar()
        updateStatusBar()
    }

    /// "Encode in" needs raw bytes on disk; an untitled buffer has none.
    func canEncodeIn(_ encoding: String) -> Bool {
        guard let doc = tabStore.selectedDocument, let path = doc.filePath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// "Convert to" is available only when the current text can actually be
    /// written in the target encoding (ASCII cannot hold emoji, for example).
    func canConvertTo(_ encoding: String) -> Bool {
        guard let doc = tabStore.selectedDocument else { return false }
        return doc.canEncode(as: encoding)
    }

    /// Changing encoding must re-decode the bytes on disk, otherwise the status
    /// bar says UTF-16 while the buffer still holds the mis-detected decode and
    /// the next save writes the wrong bytes.
    func setEncoding(_ encoding: String) {
        guard let doc = tabStore.selectedDocument else { return }
        doc.setEncoding(encoding)

        guard let path = doc.filePath, let data = try? Data(contentsOf: path) else {
            updateStatusBar()
            return
        }
        let nsEnc = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: encoding))
        if let text = String(data: data, encoding: nsEnc), text != doc.text {
            doc.text = text
            doc.setModified(true)
            updateEditor()
        }
        updateStatusBar()
    }

    func setEOL(_ eol: String) {
        guard let doc = tabStore.selectedDocument else { return }
        // convertEOL replaces through the shared storage, so the edit is
        // visible and undoable; the model notice drives the UI refresh.
        doc.convertEOL(to: eol)
        updateStatusBar()
    }

    // MARK: - Editor commands

    /// Whether a registry command would actually change the selected document.
    ///
    /// Menu validation uses the command's own pure transform, so "cannot apply"
    /// means the exact no-op cases: no document, an unknown identifier, or a
    /// command that would leave the buffer unchanged (move the first line up,
    /// change case with only a caret, delete an empty document, and so on).
    func canPerformCommand(identifier: String) -> Bool {
        guard let editor = editorContainer,
              let doc = tabStore.selectedDocument,
              let command = commandRegistry.command(for: identifier) else {
            return false
        }
        let result = command.execute(doc.text, editor.textView.selectedRange)
        return result.text != doc.text
    }

    /// Runs a registry command against the selected document.
    ///
    /// The whole command is applied as one `DocumentModel` replacement, so the
    /// change lands on the document's undo stack as a single Cmd+Z step and the
    /// shared NSTextStorage updates the visible editor immediately.
    @discardableResult
    func performCommand(identifier: String) -> Bool {
        guard let editor = editorContainer,
              let doc = tabStore.selectedDocument,
              let command = commandRegistry.command(for: identifier) else {
            return false
        }

        let original = doc.text
        let selection = editor.textView.selectedRange
        let result = command.execute(original, selection)
        guard result.text != original else { return false }

        doc.replaceCharacters(in: NSRange(location: 0, length: (original as NSString).length),
                              with: result.text)

        let textLength = (doc.text as NSString).length
        let location = min(max(0, result.selection.location), textLength)
        let length = min(max(0, result.selection.length), textLength - location)
        let restored = NSRange(location: location, length: length)
        editor.textView.setSelectedRange(restored)
        editor.textView.scrollRangeToVisible(restored)

        // The model already posted its own text-change notice. Republish the
        // document-modified notice as the existing save/close paths do so tab
        // dirty dots and the status bar update even when the command was the
        // only mutation in this run loop turn.
        NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
        return true
    }

    /// First-responder menu entry point. The menu item carries the registry
    /// identifier in `representedObject`, keeping the action selector stable
    /// while the registry grows.
    @objc func performCommand(withIdentifier sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let identifier = item.representedObject as? String else { return }
        performCommand(identifier: identifier)
    }

    // MARK: - Line operations

    /// Apply a text transform to the selection when there is one, otherwise to
    /// the whole document. LineOps shipped fully tested but had no menu at all.
    private func applyLineOp(_ transform: (String) -> String) {
        guard let editor = editorContainer, let doc = tabStore.selectedDocument else { return }
        let sel = editor.textView.selectedRange
        if sel.length > 0 {
            guard let swiftRange = Range(sel, in: doc.text) else { return }
            let slice = String(doc.text[swiftRange])
            // Mutating the shared storage keeps the visible text and the model
            // in step, and registers the transform on this document's undo stack.
            doc.replaceCharacters(in: sel, with: transform(slice))
        } else {
            doc.replaceAllText(with: transform(doc.text))
        }
    }

    func sortLinesAscending() { applyLineOp(LineOps.sortAscending) }
    func sortLinesDescending() { applyLineOp(LineOps.sortDescending) }
    func removeDuplicateLines() { applyLineOp(LineOps.removeDuplicates) }
    func removeBlankLines() { applyLineOp(LineOps.removeBlankLines) }
    
    func setLanguage(_ lang: Language) {
        if let doc = tabStore.selectedDocument {
            doc.setLanguage(lang.rawValue)
            // Force one full reset so colours from the previous language do not
            // linger outside the viewport.
            docThemeNames.removeValue(forKey: doc.id)
        }
        updateEditor()
    }
    
    // MARK: - Session
    
    func saveSession() {
        // The editor and every document share one buffer, so untitled
        // (never-saved-to-disk) edits are already in tabStore.
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
    ///
    /// Clicking a line number selects that entire logical line (content plus
    /// its line terminator, so the selection ends where the next line begins).
    /// Dragging from the gutter extends the selection across the lines it
    /// crossed, covering every full line in between. Line boundaries come from
    /// GutterGeometry, the unit-tested source of truth for line<->character
    /// math in this codebase.
    private func selectCharacter(_ charIndex: Int, anchorCharIndex: Int? = nil) {
        guard let editor = editorContainer else { return }
        let text = editor.textView.string
        let textLength = (text as NSString).length
        let clamped = min(max(0, charIndex), textLength)

        // A press on line L selects line L; dragging to line M widens the
        // selection to cover every full line from the earlier to the later one.
        let anchor = anchorCharIndex.map { min(max(0, $0), textLength) }
        let anchorLine = anchor.flatMap { GutterGeometry.logicalLine(of: $0, in: text) }
        let targetLine = GutterGeometry.logicalLine(of: clamped, in: text)
        let firstLine: Int
        let lastLine: Int
        if let anchorLine, anchorLine != targetLine {
            firstLine = min(anchorLine, targetLine)
            lastLine = max(anchorLine, targetLine)
        } else {
            firstLine = targetLine
            lastLine = targetLine
        }

        // Full logical lines: start of the first line through the start of the
        // line after the last one, which lands just past the final newline.
        let selectionStart = GutterGeometry.firstCharIndex(of: firstLine, in: text)
        let nextLineStart = GutterGeometry.firstCharIndex(of: lastLine + 1, in: text)
        let selectionEnd = min(nextLineStart, textLength)
        let selRange = NSRange(location: selectionStart, length: max(0, selectionEnd - selectionStart))

        editor.textView.setSelectedRange(selRange)
        editor.textView.scrollRangeToVisible(selRange)
    }
}

// MARK: - NSMenuItemValidation

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(MainWindowController.performCommand(withIdentifier:)) {
            guard let identifier = menuItem.representedObject as? String else { return false }
            return canPerformCommand(identifier: identifier)
        }
        if menuItem.action == #selector(MainWindowController.selectNextTab(_:))
            || menuItem.action == #selector(MainWindowController.selectPreviousTab(_:)) {
            return tabStore.count > 1
        }
        if menuItem.action == #selector(MainWindowController.selectTabByNumber(_:)) {
            return menuItem.tag >= 1 && menuItem.tag <= tabStore.count
        }
        if menuItem.action == #selector(MainWindowController.encodeIn(_:)) {
            guard let encoding = menuItem.representedObject as? String else { return false }
            menuItem.state = (tabStore.selectedDocument?.encoding == encoding) ? .on : .off
            return canEncodeIn(encoding)
        }
        if menuItem.action == #selector(MainWindowController.convertToEncoding(_:)) {
            guard let encoding = menuItem.representedObject as? String else { return false }
            menuItem.state = (tabStore.selectedDocument?.saveEncoding == encoding) ? .on : .off
            return canConvertTo(encoding)
        }
        return true
    }
}

// MARK: - NSTextViewDelegate

extension MainWindowController: NSTextViewDelegate {
    func undoManager(for textView: NSTextView) -> UndoManager? {
        editorBoundDoc?.undoManager ?? textView.undoManager
    }

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        // Remember the post-edit range so textDidChange can re-tokenize only
        // the touched line band instead of the whole document.
        pendingEditRange = NSRange(location: affectedCharRange.location,
                                   length: (replacementString ?? "").utf16.count)
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let doc = tabStore.selectedDocument, let editor = editorContainer else { return }
        let editedRange = pendingEditRange
        pendingEditRange = nil
        // NSTextView wrote straight into doc.textStorage; dirty state is
        // derived from that buffer, so only the derived UI needs refreshing.
        refreshTabBar()
        updateStatusBar()
        applySyntaxHighlighting(to: editor,
                                for: doc,
                                editedRange: editedRange,
                                forceReset: editedRange == nil)
        // Republish the model's own change notice so observers (find counts)
        // see typing through the same path as programmatic replace/line edits.
        // Tagging it with the edited range lets this controller's own observer
        // recognise the already-handled incremental path instead of repeating
        // the highlight and UI refresh.
        var userInfo: [AnyHashable: Any] = [:]
        if let editedRange {
            userInfo["editedRange"] = NSValue(range: editedRange)
        }
        NotificationCenter.default.post(name: DocumentModel.textDidChangeNotification,
                                        object: doc,
                                        userInfo: userInfo)
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
