import AppKit
import HexpadKit

class MainWindowController: NSViewController {
    
    /// The two tab groups. Two independent TabStore instances (rather than one
    /// store with group membership) keep every existing command path working
    /// against "the focused store"; a tab move between groups is a document
    /// move between the two stores. Group 1 always exists; group 2 is created by
    /// View > Toggle Split View and starts empty.
    private let primaryPane = TabGroupPane(group: .primary)
    private var secondaryPane: TabGroupPane?
    private(set) var focusedGroup: TabGroup = .primary

    /// True for a window opened with File > New Window. Additional windows do
    /// not write the (single) session on their own; the app delegate merges
    /// every window into one snapshot on quit and when a window closes.
    var isAdditionalWindow = false

    /// First-bind state per group. A fresh empty pane still needs its theme and
    /// preferences applied once even when its document id is nil.
    private var hasBoundPrimaryPane = false
    private var hasBoundSecondaryPane = false

    /// The focused group's store. With the split closed this is group 1, which
    /// is exactly the old single-store behaviour.
    var tabStore: TabStore { activePane.tabStore }

    private var activePane: TabGroupPane {
        focusedGroup == .secondary ? (secondaryPane ?? primaryPane) : primaryPane
    }

    var allPanes: [TabGroupPane] {  // harness-visible (was private)
        secondaryPane.map { [primaryPane, $0] } ?? [primaryPane]
    }

    /// Panes with the focused one last, for passes whose shared end state must
    /// belong to the editor that can receive keystrokes (highlighting).
    private var panesFocusedLast: [TabGroupPane] {
        focusedGroup == .primary ? Array(allPanes.reversed()) : allPanes
    }

    var isSplitViewOpen: Bool { secondaryPane != nil }

    private var mainWindow: MainWindow?
    var recentFilesManager: RecentFilesManager?

    /// Menu/keybinding layer for the editor commands. The registry itself is
    /// Kit-owned; this controller only resolves and applies its commands to the
    /// selected document.
    private let commandRegistry = CommandRegistry.default

    /// The macro being recorded (or the last one stopped). This is the one
    /// place recording state lives. `performCommand` is the single capture
    /// point that feeds it: line edits, bookmark commands, Tools (hash and
    /// date/time), Line Ops and the view-only fold/wrap commands all funnel
    /// through it, so no macro-recordable action can reach the editor without
    /// being recorded while this model is recording.
    ///
    /// Recording and replay are deliberately asymmetric for view-only commands.
    /// Text commands (everything except fold-all/unfold-all/toggle-word-wrap)
    /// replay through `MacroModel` against document state. View commands are
    /// recorded and can be replayed as no-ops only: folding and wrapping live in
    /// the editor view, not in `DocumentState`, so a replay reports those steps
    /// as skipped instead of silently pretending they ran.
    private(set) var macroRecorder = MacroModel(name: "Macro")

    /// The most recent recording or saved macro played, used by Play Last Macro.
    private(set) var lastMacro: MacroModel?

    /// Pending timer that clears a transient window-subtitle status flash.
    private var statusFlashWorkItem: DispatchWorkItem?

    /// The text view backing the focused document. Exposed for menu
    /// validation/action tests in the app test bundle.
    var editorTextView: NSTextView? { editorContainer?.textView }

    /// Whether the macro recorder is currently appending commands.
    var isRecordingMacro: Bool { macroRecorder.isRecording }
    
    // Subviews. The focused group's views are reached through these computed
    // names, so the existing command paths follow focus without a second copy
    // of each action.
    private var editorContainer: EditorContainer? { activePane.editor }
    private var statusBar: StatusBar?
    /// Exposed for app tests (find-bar counts/highlight behaviour) and refreshed
    /// only through `refreshChrome`'s injected refs.
    private(set) var findBar: FindBar?
    private var dividerView: NSView?
    /// Routes clicks in either group's editor/tab bar to ``focusGroup(_:)``.
    private var mouseDownMonitor: Any?

    /// Reused document switcher overlay (N++ style). Created on first use so a
    /// window with no documents never pays for it.
    private var docSwitcherController: DocSwitcherWindowController?

    /// View > Synchronize Scrolling. Defaults to on and is remembered in
    /// UserDefaults, alongside the other view-only state that is not part of
    /// the document/session model.
    private(set) var synchronizeScrolling: Bool = {
        UserDefaults.standard.object(forKey: "synchronizeScrolling") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "synchronizeScrolling")
    }()

    /// Re-entrancy guard for the leader/follower scroll pair. Set while the
    /// follower is being scrolled; the follower's own coalesced viewport
    /// notification is ignored, so one wheel event cannot bounce between panes.
    private var isPropagatingScroll = false

    /// Single reusable Function List panel. The View item is nil-targeted, so
    /// this controller owns both the toggle and the no-document validation.
    private var functionListController: FunctionListWindowController?
    /// Debounces outline rebuilds while typing. The panel is a view of the
    /// document, so bursts of edits should produce one model scan, not one per
    /// keystroke.
    private var functionListRefreshWorkItem: DispatchWorkItem?
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

    /// Persisted user preferences. Loaded once at controller creation and kept
    /// current by the `.preferencesDidChange` observer, so every bind and
    /// re-highlight reads one value instead of the file.
    private(set) var preferences = PreferencesStore.load()
    
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
        statusFlashWorkItem?.cancel()
        statusFlashWorkItem = nil
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
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
        // Preferences are saved from their own window; the controller applies
        // them to whichever editor is on screen, so a change made there is not
        // lost on the next tab switch.
        NotificationCenter.default.addObserver(self, selector: #selector(handlePreferencesDidChange(_:)), name: .preferencesDidChange, object: nil)
        // Live Ln/Col: caret moves (arrows, clicks, typing, find navigation,
        // programmatic selection) all post this notification from the text view.
        textSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSTextViewDidChangeSelectionNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusBar()
        }
        // Clicking in either group focuses it. A local monitor is enough here
        // because the groups are siblings in this window; the event still runs
        // its normal dispatch afterwards, so caret placement is unaffected.
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.noteMouseDownForFocus(event)
            return event
        }
    }

    /// Focuses the group whose tab bar or editor contains the click. Clicks on
    /// the shared chrome (find bar, status bar, divider) leave focus alone, so
    /// the find bar keeps acting on the group the user last edited.
    private func noteMouseDownForFocus(_ event: NSEvent) {
        guard isSplitViewOpen, let window = view.window, event.window === window else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        if primaryPane.editor.frame.contains(point) || primaryPane.tabScrollView.frame.contains(point) {
            focusGroup(.primary)
        } else if let secondary = secondaryPane,
                  secondary.editor.frame.contains(point) || secondary.tabScrollView.frame.contains(point) {
            focusGroup(.secondary)
        }
    }

    @objc private func handleFindBarClosed(_ notification: Notification) {
        updateLayout()
        if let editor = editorContainer {
            view.window?.makeFirstResponder(editor.textView)
        }
    }

    /// Applies a live preference change to the selected editor.
    ///
    /// This is the single live-apply path: `PreferencesStore` posts
    /// `.preferencesDidChange` with the normalized value, and observers apply
    /// that value directly. Nothing re-reads the file or applies preferences a
    /// second time, so font, wrap, and theme can never be applied twice or in
    /// two different orders.
    ///
    /// Font and theme are global editor settings. Word wrap is still owned by
    /// each document (`DocumentModel.editorState`), so changing the preference
    /// goes through ``EditorContainer/setWordWrapEnabled(_:)``, which writes the
    /// value through to the selected tab, making it that tab's explicit value;
    /// other tabs keep their own state and new tabs use the preference as their
    /// default.
    @objc private func handlePreferencesDidChange(_ notification: Notification) {
        guard let updated = notification.object as? Preferences else { return }
        let previous = preferences
        // The notification object is the value the store normalized before
        // writing, so this is the applied truth; do not re-read from disk.
        preferences = updated.normalized()
        guard previous != preferences else { return }

        // Font and wrap are per editor container; theme is applied through the
        // highlighting pass. Every open group is updated so switching groups
        // never shows a stale font or palette.
        for pane in allPanes {
            pane.editor.setBodyFont(PreferencesApplier.resolvedFont(family: preferences.fontFamily,
                                                                    size: preferences.fontSize))

            if previous.wordWrap != preferences.wordWrap {
                // Write-through: the container persists the new value on its
                // bound document. A direct text view or model write here would
                // be a second, order-dependent path.
                pane.editor.setWordWrapEnabled(preferences.wordWrap)
            }
        }

        if previous.theme != preferences.theme {
            for pane in panesFocusedLast {
                if let doc = pane.tabStore.selectedDocument {
                    rehighlightAll(in: pane.editor, document: doc)
                }
            }
        }
    }
    
    @objc private func handleTabCloseRequested(_ notification: Notification) {
        // The close button can live in either group's bar. Focus that group
        // first so the index and the save prompt act on its store.
        if let sourceBar = notification.userInfo?["tabBar"] as? TabBarView {
            if let secondaryPane, sourceBar === secondaryPane.tabBar {
                focusGroup(.secondary)
            } else if sourceBar === primaryPane.tabBar {
                focusGroup(.primary)
            }
        }
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
        // Persist the session on the same notice that refreshes the tab dots.
        // SessionStore coalesces bursts into one write, so this is not a
        // write per change.
        scheduleSessionSave()
        refreshDirtyIndicators()
        updateStatusBar()
        updateWindowTitle()
    }

    @objc private func handleModelTextChange(_ notification: Notification) {
        guard let doc = notification.object as? DocumentModel else { return }

        // Typing reaches this path too (NSTextViewDelegate republishes the
        // model notice), so this is the keystroke-driven session save. The
        // store's debounce collapses a typing burst into one write.
        scheduleSessionSave()

        // The Function List is a view of the same buffer: coalesce outline
        // rebuilds here, before the typing-specific early return below, so both
        // typing and programmatic edits keep it live.
        scheduleFunctionListUpdate()

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

        // Group 1. A pane owns its tab bar, scroll view and editor, so opening
        // group 2 later is the same construction plus a divider.
        view.addSubview(primaryPane.tabScrollView)
        view.addSubview(primaryPane.editor)
        wire(primaryPane)
        
        let status = StatusBar()
        view.addSubview(status)
        statusBar = status
        status.autoresizingMask = [.width, .maxYMargin]
        
        let find = FindBar()
        view.addSubview(find)
        findBar = find
        find.tabStoreRef = primaryPane.tabStore
        find.editorRef = primaryPane.editor
        find.setupObservers()
        
        updateLayout()
    }

    /// Connects a pane's editor and tab bar to the controller. Shared by both
    /// groups so they cannot drift in what they wire.
    private func wire(_ pane: TabGroupPane) {
        pane.editor.textView.delegate = self
        let group = pane.group
        pane.editor.onViewportChange = { [weak self] in
            self?.handleViewportChange(in: group)
        }
        pane.editor.onAppearanceChange = { [weak self] in
            self?.handleAppearanceChange()
        }

        let ruler = pane.editor.ruler as? LineNumberGutter
        ruler?.setClickHandler { [weak self] charIndex, anchorCharIndex in
            self?.selectCharacter(charIndex, anchorCharIndex: anchorCharIndex)
        }

        pane.tabBar.onFocus = { [weak self] in
            self?.focusGroup(group)
        }
        pane.tabBar.onChange = { [weak self] in
            self?.handlePaneTabChange()
        }
    }
    
    private func updateLayout() {
        guard let status = statusBar else { return }

        let tabBarHeight: CGFloat = 32
        let statusHeight: CGFloat = 22

        // The find bar always occupies its slot when visible; hidden state is
        // expressed with isHidden, so a resize never leaves a stale rect for a
        // bar that would then reappear in the wrong place.
        let findVisible = findBar?.isVisible ?? false
        let findHeight = findBar?.preferredHeight(for: view.bounds.width) ?? 36
        let topInset = tabBarHeight + (findVisible ? findHeight : 0)
        let height = view.bounds.height
        let width = view.bounds.width

        // The divider is one point of chrome between the two groups. Keeping
        // the single-group widths untouched when the split is closed preserves
        // the original layout math exactly.
        let dividerWidth: CGFloat = isSplitViewOpen ? 1 : 0
        let primaryWidth = isSplitViewOpen
            ? max(0, floor((width - dividerWidth) / 2))
            : width

        layoutPane(primaryPane,
                   x: 0,
                   width: primaryWidth,
                   height: height,
                   topInset: topInset,
                   statusHeight: statusHeight,
                   tabBarHeight: tabBarHeight)

        let editorTop = height - topInset
        let editorHeight = max(editorTop - statusHeight, 100)

        if let secondary = secondaryPane {
            let x = primaryWidth + dividerWidth
            layoutPane(secondary,
                       x: x,
                       width: max(0, width - x),
                       height: height,
                       topInset: topInset,
                       statusHeight: statusHeight,
                       tabBarHeight: tabBarHeight)
            dividerView?.isHidden = false
            dividerView?.frame = NSRect(x: primaryWidth,
                                        y: statusHeight,
                                        width: dividerWidth,
                                        height: editorHeight)
        } else {
            dividerView?.isHidden = true
        }

        findBar?.frame = NSRect(x: 0,
                                y: max(statusHeight, height - topInset),
                                width: width,
                                height: findHeight)

        status.frame = NSRect(x: 0, y: 0, width: width, height: statusHeight)
    }

    /// Lays out one group's tab bar and editor inside its horizontal slice.
    private func layoutPane(_ pane: TabGroupPane,
                            x: CGFloat,
                            width: CGFloat,
                            height: CGFloat,
                            topInset: CGFloat,
                            statusHeight: CGFloat,
                            tabBarHeight: CGFloat) {
        pane.tabScrollView.frame = NSRect(x: x,
                                          y: max(0, height - tabBarHeight),
                                          width: width,
                                          height: tabBarHeight)
        pane.tabBar.frame.size.height = tabBarHeight
        pane.tabBar.fitWidthToClip()

        let editorTop = height - topInset
        let editorHeight = max(editorTop - statusHeight, 100)
        pane.editor.frame = NSRect(x: x,
                                   y: statusHeight,
                                   width: width,
                                   height: editorHeight)
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
        // The preference is the default for a document that has no persisted
        // editor state of its own. Restored tabs keep the state the session
        // stored; this only seeds newly created buffers.
        doc.wordWrapEnabled = preferences.wordWrap
        tabStore.addDocument(doc)
        refreshTabBar()
        updateEditor()
        updateStatusBar()
        postTabSelectionDidChange()
    }
    
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Accept any file type so users can open documents of arbitrary kind.
        
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
        // Dedupe: if a tab already shows this file, switch to that tab instead of
        // opening a second one. A dirty buffer keeps the user's unsaved edits;
        // a clean one may have changed on disk since it was opened, so reload it
        // through the same path the external-change watcher uses before focusing.
        // Both split groups are searched: two DocumentModels for one path would
        // be two independent buffers and undo stacks for the same file.
        if let existing = existingOpenDocument(forPath: url.path) {
            let existingDoc = existing.document
            var didReload = false
            if !existingDoc.unsavedChanges {
                didReload = reloadDocument(existingDoc, from: url)
            }
            // Focus the owning group before selecting: all tab commands act on
            // the focused store, and the match may live in the other group.
            focusGroup(existing.pane.group)
            selectTab(at: existing.index)
            if didReload {
                // The reload swapped the buffer, so force the chrome to re-read
                // the new text even when the tab was already selected (selectTab
                // early-returns in that case and would skip the refresh).
                refreshTabBar()
                updateEditor(forceRebind: true)
                updateStatusBar()
            }
            recentFilesManager?.addRecent(url.path)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let encoding = EncodingDetective.detect(data)
            // Strip a leading BOM before decoding: String(data:encoding:) with
            // an explicit UTF-16LE decoder keeps U+FEFF in the buffer, which
            // showed up as a stray character at position 0.
            let text = EncodingDetective.decodeForEditing(data, as: encoding) ?? ""
            // A recognized extension always wins; only unknown/plain-text
            // files are sniffed, so opening modern-language sources never
            // triggers a spurious Language Mismatch prompt.
            let finalLang = ContentSniffer.resolveLanguage(
                fileName: url.lastPathComponent,
                data: data
            )
            
            let doc = DocumentModel(text: text, filePath: url, encoding: encoding)
            doc.keepsBOM = EncodingDetective.detectBOM(of: data) != nil
            doc.setLanguage(finalLang.rawValue)
            // A file opened now is a new tab: the word-wrap preference is its
            // default. A restored session keeps the per-document value.
            doc.wordWrapEnabled = preferences.wordWrap
            tabStore.addDocument(doc)
            refreshTabBar()
            updateEditor()
            updateStatusBar()
            recentFilesManager?.addRecent(url.path)
        } catch {
            showError("Failed to open file: \(error.localizedDescription)")
        }
    }
    
    /// The open tab showing `path`, searching both split groups. The focused
    /// group is searched first so a legacy state that somehow holds two tabs for
    /// one file still resolves to the one the user is looking at.
    private func existingOpenDocument(forPath path: String)
        -> (pane: TabGroupPane, index: Int, document: DocumentModel)? {
        let panes = [activePane] + allPanes.filter { $0 !== activePane }
        for pane in panes {
            if let index = pane.tabStore.documents.firstIndex(where: { $0.filePath?.path == path }) {
                return (pane, index, pane.tabStore.documents[index])
            }
        }
        return nil
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
    
    // MARK: - Print

    /// File > Print… (Cmd+P). Prints the focused group's current document
    /// using a custom paginated view so headers, footers and line numbers line
    /// up with the printed text.
    ///
    /// Notepad++ behaviour: if the editor has a non-empty selection, printing
    /// is selection-only. There is deliberately no prompt; the selection's
    /// presence is the choice.
    @objc func printDocument(_ sender: Any?) {
        guard let doc = tabStore.selectedDocument,
              let editor = editorContainer else { return }

        let nsText = doc.text as NSString
        let selection = editor.textView.selectedRange
        let safeSelection = NSIntersectionRange(selection,
                                                NSRange(location: 0, length: nsText.length))

        let text: String
        let firstLine: Int
        if safeSelection.length > 0 {
            text = nsText.substring(with: safeSelection)
            // Keep printed line numbers aligned with the editor for a
            // selection: the prefix's newline count is the preceding line
            // count, so the selection starts on line count.
            let prefix = nsText.substring(to: safeSelection.location)
            firstLine = prefix.components(separatedBy: "\n").count
        } else {
            text = doc.text
            firstLine = 1
        }

        let printView = PrintDocumentView(text: text,
                                          font: editor.bodyFont,
                                          fileName: doc.name,
                                          filePath: doc.filePath?.path,
                                          showsLineNumbers: true,
                                          firstLineNumber: firstLine)

        let info = NSPrintInfo()
        info.paperSize = PrintDocumentView.pageSize
        info.orientation = .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.scalingFactor = 1
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        if let window = view.window ?? mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Print… needs a selected document.
    func canPrintDocument() -> Bool {
        tabStore.selectedDocument != nil
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
        let closed = (index >= 0 && index < tabStore.count) ? tabStore.documents[index] : nil
        tabStore.removeDocument(at: index)
        refreshTabBar()
        updateEditor()
        updateStatusBar()
        postTabSelectionDidChange()

        // Forget per-document caches (fold/bookmark models, theme tags, watcher
        // baselines) once the document is no longer open anywhere, so a long
        // session cannot retain every closed tab's state.
        if let closed,
           !allPanes.contains(where: { $0.tabStore.documents.contains { $0 === closed } }) {
            allPanes.forEach { $0.editor.forgetDocumentState(for: closed.id) }
            docThemeNames.removeValue(forKey: closed.id)
            seenModDates.removeValue(forKey: closed.id)
        }

        // Refill only when the whole window is empty: closing one group's last
        // tab while the other group still has documents leaves that group empty
        // instead of spawning a tab the user did not ask for.
        if tabStore.count == 0 && allPanes.allSatisfy({ $0.tabStore.isEmpty }) {
            focusedGroup = .primary
            addNewTab()
        }
    }

    /// Closes `doc` in whichever group owns it. Focus follows the document so
    /// the normal close path (index, selection, chrome, empty-group handling)
    /// applies even while the other group was focused.
    private func closeDocument(_ doc: DocumentModel) {
        guard let pane = allPanes.first(where: { $0.tabStore.documents.contains { $0 === doc } }),
              let index = pane.tabStore.documents.firstIndex(where: { $0 === doc }) else { return }
        focusGroup(pane.group)
        closeTabAtIndex(index)
    }
    
    func closeAllTabs() {
        // "All tabs" is window-scoped: close both split groups. Each group is
        // walked back-to-front so removing a higher index never shifts a lower
        // one into an already-processed slot. Dirty docs get the same save
        // prompt as a single close; Cancel stops the sweep and leaves the
        // remaining tabs open.
        var queue: [(pane: TabGroupPane, doc: DocumentModel)] = []
        for pane in allPanes {
            queue.append(contentsOf: pane.tabStore.documents.reversed().map { (pane, $0) })
        }
        guard !queue.isEmpty else {
            addNewTab()
            return
        }

        var index = 0
        var shouldContinueClosing = true

        func closeNextTab() {
            guard shouldContinueClosing, index < queue.count else { return }
            let (pane, doc) = queue[index]
            // The document may already be gone (closed while a sheet ran).
            guard pane.tabStore.documents.contains(where: { $0 === doc }) else {
                index += 1
                closeNextTab()
                return
            }

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
                                self.focusGroup(pane.group)
                                guard self.saveAsAndClose(doc) else {
                                    shouldContinueClosing = false
                                    return
                                }
                            } else {
                                self.saveDocument(doc)
                                self.closeDocument(doc)
                            }
                            index += 1
                            closeNextTab()
                        case .alertSecondButtonReturn: // Don't Save
                            self.closeDocument(doc)
                            index += 1
                            closeNextTab()
                        case .alertThirdButtonReturn: // Cancel
                            shouldContinueClosing = false
                        default:
                            shouldContinueClosing = false
                        }
                    }
                }
            } else {
                closeDocument(doc)
                index += 1
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
        // Every tab-switch path shares this notice (FindBar and the tab bars
        // observe it). Posting only from the tab-bar click path left the find
        // bar's counts and highlights on the previous document after
        // Cmd+Shift+] / Cmd+1-9 / the document switcher / Open.
        postTabSelectionDidChange()
    }

    /// Announces that the focused group's selected tab changed. Kept in one
    /// place so programmatic and mouse-driven selection cannot drift again.
    private func postTabSelectionDidChange() {
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"),
                                        object: nil)
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
        allPanes.forEach { $0.tabBar.reloadTabs() }
    }
    
    func updateEditor(forceRebind: Bool = false) {
        bindChangedPanes(force: forceRebind)
        refreshChrome()
    }

    /// Binds only panes whose selected document actually changed. Focus
    /// changes and chrome refreshes therefore never rescan unchanged buffers.
    private func bindChangedPanes(force: Bool) {
        for pane in allPanes {
            let doc = pane.tabStore.selectedDocument
            let everBound = pane.group == .primary ? hasBoundPrimaryPane : hasBoundSecondaryPane
            let languageChanged = pane.editor.boundLanguage != doc?.language
            if force || !everBound || pane.boundDocument?.id != doc?.id || languageChanged {
                bind(pane, force: force)
            }
        }
    }

    /// Binds one group's editor to its store's selected document. The document
    /// owns the storage, undo stack and editor state, so two panes never share
    /// selection, scroll, dirty state or text.
    private func bind(_ pane: TabGroupPane, force: Bool) {
        if pane.group == .primary {
            hasBoundPrimaryPane = true
        } else {
            hasBoundSecondaryPane = true
        }
        if let doc = pane.tabStore.selectedDocument {
            pane.boundDocument = doc
            // bind() captures the outgoing document's caret/scroll/wrap/zoom
            // and applies the incoming document's state. Same-document binds
            // are skipped inside the container unless `force` asks for a real
            // re-adoption (language change, reload).
            pane.editor.bind(to: doc, force: force)
            // Font is a global preference; wrap comes from the document once
            // it exists. bind() has already restored the caret, so nothing
            // here can clobber a restored selection.
            applyPreferences(to: pane.editor, for: doc)
            pane.editor.apply(theme: theme(for: pane.editor))
        } else {
            pane.boundDocument = nil
            pane.editor.bind(to: nil, force: force)
            applyPreferences(to: pane.editor, for: nil)
            pane.editor.apply(theme: theme(for: pane.editor))
        }
    }

    /// Updates the shared chrome and repaints the focused pane's visible band.
    /// Does no document binding, so focus changes stay O(visible).
    private func refreshChrome() {
        let pane = activePane
        findBar?.tabStoreRef = pane.tabStore
        findBar?.editorRef = pane.editor

        if let doc = pane.tabStore.selectedDocument {
            applySyntaxHighlighting(to: pane.editor, for: doc, forceReset: true)
        } else {
            highlightedDoc = nil
            syntaxStore.reset()
            lastHighlightedRange = NSRange(location: 0, length: 0)
        }

        updateStatusBar()
        updateWindowTitle()
        // Tab/language changes replace the outline rather than editing it, so
        // this path is not debounced. A no-op when the panel is closed.
        refreshFunctionListImmediately()
    }

    /// Refreshes after a tab bar mutates its own store (click, reorder, or a
    /// cross-group drag). The bar has already reloaded itself; only the
    /// changed pane needs binding.
    private func handlePaneTabChange() {
        updateEditor()
    }

    /// Makes `group` the focused group. Find and every Tools/Text command act
    /// on the focused group's selected document, so that is the only state a
    /// focus change needs to move.
    func focusGroup(_ group: TabGroup) {
        if group == .secondary && secondaryPane == nil { return }
        guard group != focusedGroup else { return }
        focusedGroup = group
        // Bind first, then refresh chrome. A focus change can be the first thing
        // to happen after a store's selection moved (Move to Other View and a
        // cross-group drop both select the incoming tab before focusing its
        // group), so highlighting the new document against the pane's previous
        // storage would index past the old buffer. updateEditor is
        // bind-guarded: an unchanged pane costs no document work.
        updateEditor()
        if findBar?.isVisible == true {
            findBar?.performFind()
        }
    }

    /// Typing: update only existing dirty dots. No reload, no full-text
    /// comparison per tab.
    private func refreshDirtyIndicators() {
        allPanes.forEach { $0.tabBar.updateDirtyIndicators() }
    }

    /// The pane whose editor owns `textView`. Used by undo routing so a text
    /// view in either group resolves against its own bound document.
    private func pane(containing textView: NSTextView) -> TabGroupPane? {
        allPanes.first { $0.editor.textView === textView }
    }

    // MARK: - Document switcher

    /// View > Document Switcher… (Cmd+Tab). Lists every tab in both groups.
    @objc func showDocumentSwitcher(_ sender: Any?) {
        guard canShowDocumentSwitcher(), let parent = view.window else { return }

        let switcher = docSwitcherController ?? DocSwitcherWindowController()
        docSwitcherController = switcher
        switcher.onChoose = { [weak self] item in
            self?.switchToDocument(item)
        }
        switcher.onCancel = { [weak self] in
            self?.returnFocusAfterSwitcher()
        }
        switcher.show(over: parent,
                      items: documentSwitcherItems(),
                      selectedDocumentID: activePane.tabStore.selectedDocument?.id)
    }

    /// The switcher needs at least one document in either group.
    func canShowDocumentSwitcher() -> Bool {
        allPanes.contains { !$0.tabStore.isEmpty }
    }

    /// Every open tab in tab order, group 1 first. The overlay only renders
    /// this list; selection and focus stay in this controller.
    private func documentSwitcherItems() -> [DocSwitcherItem] {
        allPanes.flatMap { pane in
            pane.tabStore.documents.map { doc in
                DocSwitcherItem(documentID: doc.id,
                                 name: doc.name,
                                 directory: doc.filePath?.deletingLastPathComponent().path ?? "Unsaved",
                                 group: pane.group)
            }
        }
    }

    /// Resolves the chosen identity against its group's store, selects it there
    /// through the normal tab path, and leaves focus in that group.
    private func switchToDocument(_ item: DocSwitcherItem) {
        guard let pane = pane(for: item.group),
              let index = pane.tabStore.documents.firstIndex(where: { $0.id == item.documentID }) else {
            returnFocusAfterSwitcher()
            return
        }
        focusGroup(item.group)
        selectTab(at: index)
        returnFocusAfterSwitcher()
    }

    /// Closes the overlay's key status and hands the keyboard back to the
    /// focused group's editor. Called for both Enter and Escape paths.
    private func returnFocusAfterSwitcher() {
        view.window?.makeKey()
        view.window?.makeFirstResponder(activePane.editor.textView)
    }

    // MARK: - Split view

    /// View > Toggle Split View. Opens or closes the second group.
    @objc func toggleSplitView(_ sender: Any?) {
        if isSplitViewOpen {
            closeSplitView()
        } else {
            openSplitView()
        }
    }

    /// View > Synchronize Scrolling. Inert while the split is closed (the menu
    /// item is disabled); the setting itself is remembered for next launch.
    @objc func toggleSynchronizeScrolling(_ sender: Any?) {
        synchronizeScrolling.toggle()
        UserDefaults.standard.set(synchronizeScrolling, forKey: "synchronizeScrolling")
    }

    /// View > Move to Other View. Moves the focused group's selected tab into
    /// the other group and leaves focus there. Live caret/scroll is captured
    /// first; dirty state, undo stack and editor state travel with the
    /// DocumentModel, and the transfer reuses the drag path's store move.
    @objc func moveToOtherView(_ sender: Any?) {
        guard canMoveToOtherView(),
              let receiving = pane(for: focusedGroup == .primary ? .secondary : .primary) else { return }

        let source = activePane
        let index = source.tabStore.selectedIndex
        guard index >= 0, index < source.tabStore.count else { return }
        let doc = source.tabStore.documents[index]

        // The document stores caret/scroll/wrap/zoom; capture the live values
        // before the pane unbinds so the receiving editor restores them.
        source.editor.captureEditorState()
        source.tabBar.transferTab(at: index,
                                  doc: doc,
                                  to: receiving.tabBar,
                                  at: receiving.tabStore.count)
        focusGroup(receiving.group)
    }

    /// Opens group 2. It starts empty by design: the user drags tabs into it.
    func openSplitView() {
        guard secondaryPane == nil else { return }
        let pane = TabGroupPane(group: .secondary)
        secondaryPane = pane

        view.addSubview(pane.tabScrollView)
        view.addSubview(pane.editor)
        wire(pane)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.addSubview(divider)
        dividerView = divider

        pane.tabBar.siblingTabBar = primaryPane.tabBar
        primaryPane.tabBar.siblingTabBar = pane.tabBar

        updateLayout()
        updateEditor()
    }

    /// Closes group 2 and returns its tabs to group 1. Documents are never
    /// discarded: a group close is a layout change, not a close-all.
    func closeSplitView() {
        guard let pane = secondaryPane else { return }

        pane.editor.bind(to: nil)
        pane.boundDocument = nil

        let docs = pane.tabStore.documents
        let previousSelection = primaryPane.tabStore.selectedIndex
        pane.tabStore.closeAll()
        primaryPane.tabStore.documents.append(contentsOf: docs)
        if !primaryPane.tabStore.documents.isEmpty {
            primaryPane.tabStore.selectedIndex = min(previousSelection,
                                                     primaryPane.tabStore.documents.count - 1)
        }

        pane.tabBar.siblingTabBar = nil
        primaryPane.tabBar.siblingTabBar = nil
        pane.tabScrollView.removeFromSuperview()
        pane.editor.removeFromSuperview()
        dividerView?.removeFromSuperview()
        dividerView = nil
        secondaryPane = nil
        focusedGroup = .primary
        findBar?.tabStoreRef = primaryPane.tabStore
        findBar?.editorRef = primaryPane.editor

        updateLayout()
        refreshTabBar()
        updateEditor()
    }

    /// Move to Other View needs an open split and a tab in the focused group.
    func canMoveToOtherView() -> Bool {
        isSplitViewOpen && tabStore.selectedDocument != nil
    }

    /// Synchronized scrolling only has meaning while both groups are open.
    func canSynchronizeScrolling() -> Bool {
        isSplitViewOpen
    }

    /// Applies the persisted font and word-wrap defaults to the bound editor.
    ///
    /// Font is a global preference and always wins. Word wrap is per document:
    /// `bind()` has already applied `editorState.wordWrapEnabled`, which is
    /// authoritative once the tab exists. Only an unbound editor uses the
    /// preference directly (and new documents are seeded from it at creation).
    private func applyPreferences(to editor: EditorContainer, for document: DocumentModel?) {
        editor.setBodyFont(PreferencesApplier.resolvedFont(family: preferences.fontFamily,
                                                            size: preferences.fontSize))
        editor.setWordWrapEnabled(document?.wordWrapEnabled ?? preferences.wordWrap)
    }

    /// Re-applies persisted preferences to the editors. The app delegate calls
    /// this once at launch, after session restore; tab binds use the same
    /// helper so startup and switching cannot disagree.
    func applyPreferences() {
        for pane in allPanes {
            applyPreferences(to: pane.editor, for: pane.tabStore.selectedDocument)
        }
        if let doc = tabStore.selectedDocument {
            rehighlightAll(in: activePane.editor, document: doc)
        }
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
        // The editor must already be showing this document's buffer. Every
        // caller either binds first or works on the focused pane; a mismatch
        // here would paint offsets from `doc` onto a different (possibly
        // shorter) storage and raise NSRangeException, so refuse instead.
        guard textStorage === doc.textStorage else { return }

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

    private func pane(for group: TabGroup) -> TabGroupPane? {
        group == .primary ? primaryPane : secondaryPane
    }

    /// Shared viewport hook: keep the incremental highlighting current for the
    /// pane that actually scrolled, then (when enabled and split) drive the
    /// other editor to the same fractional vertical offset.
    private func handleViewportChange(in group: TabGroup) {
        refreshVisibleHighlighting(in: group)
        synchronizeScroll(from: group)
    }

    /// Leader/follower scroll sync. Whichever pane moved is the leader for that
    /// event; the follower is scrolled to the same fraction of its own maximum
    /// vertical offset, so documents of different lengths stay aligned.
    private func synchronizeScroll(from group: TabGroup) {
        guard isSplitViewOpen,
              synchronizeScrolling,
              !isPropagatingScroll,
              let source = pane(for: group),
              let target = pane(for: group == .primary ? .secondary : .primary),
              source.tabStore.selectedDocument != nil,
              target.tabStore.selectedDocument != nil,
              let fraction = verticalScrollFraction(in: source.editor) else { return }

        let clip = target.editor.scrollView.contentView
        let documentHeight = target.editor.scrollView.documentView?.bounds.height ?? 0
        let maxY = max(0, documentHeight - clip.bounds.height)
        let targetY = fraction * maxY

        isPropagatingScroll = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
        target.editor.scrollView.reflectScrolledClipView(clip)
        // The follower's viewport notification is coalesced on the next main
        // queue turn; clearing after that turn keeps it from echoing back.
        DispatchQueue.main.async { [weak self] in
            self?.isPropagatingScroll = false
        }
    }

    /// Current vertical position as a 0...1 fraction of the scrollable range.
    /// `nil` when the document cannot scroll vertically at all.
    private func verticalScrollFraction(in editor: EditorContainer) -> CGFloat? {
        let clip = editor.scrollView.contentView
        let documentHeight = editor.scrollView.documentView?.bounds.height ?? 0
        let maxY = documentHeight - clip.bounds.height
        guard maxY > 0.5 else { return nil }
        return min(max(clip.bounds.origin.y / maxY, 0), 1)
    }

    /// Scroll/resize hook: only re-run the pipeline when the viewport leaves
    /// the band that is already highlighted.
    ///
    /// Uses the pane that scrolled, not the focused one: a mouse wheel over the
    /// other split group (which does not change first responder) must still
    /// tokenize the lines it brings into view.
    private func refreshVisibleHighlighting(in group: TabGroup) {
        guard let pane = pane(for: group),
              let doc = pane.tabStore.selectedDocument else { return }
        let editor = pane.editor
        // The pane must already show this document's buffer; a focus/selection
        // ordering hole must never paint this document's offsets onto another
        // storage (applySyntaxHighlighting refuses that too).
        guard editor.textView.textStorage === doc.textStorage else { return }

        let textLength = (doc.text as NSString).length
        let visible = clipped(editor.visibleCharacterRange(), to: textLength)
        if highlightedDoc === doc,
           lastHighlightedRange.length > 0,
           visible.location >= lastHighlightedRange.location,
           NSMaxRange(visible) <= NSMaxRange(lastHighlightedRange) {
            return
        }
        applySyntaxHighlighting(to: editor, for: doc)
    }

    /// The theme used for token colors.
    ///
    /// Preferences are the persisted source of truth. System (the default)
    /// resolves through ``HexpadTheme/forAppearance(_:)`` against the editor's
    /// effective appearance at apply time, so a fresh install in dark mode
    /// paints the dark palette instead of white-on-white. An explicit
    /// Light/Dark/Classic/Monokai choice wins over the appearance. Re-resolution
    /// happens on every bind and appearance change; the saved preference is not
    /// rewritten.
    private func theme(for editor: EditorContainer) -> Theme {
        preferences.themePreference.resolvedTheme(for: editor.effectiveAppearance).theme
    }

    /// Re-resolves the palette after macOS light/dark switches. System follows
    /// the new appearance; explicit themes repaint identically (and are cheap
    /// to reapply because the cached theme record was invalidated).
    private func handleAppearanceChange() {
        for pane in panesFocusedLast {
            guard let doc = pane.tabStore.selectedDocument else { continue }
            rehighlightAll(in: pane.editor, document: doc)
        }
    }

    /// Repaints every token in the bound document with the current theme.
    /// Theme is global, not per document, so all cached theme records are
    /// invalidated and the visible band is re-tokenized once.
    private func rehighlightAll(in editor: EditorContainer, document: DocumentModel) {
        docThemeNames.removeAll()
        lastHighlightedRange = NSRange(location: 0, length: 0)
        syntaxStore.reset()
        applySyntaxHighlighting(to: editor, for: document, forceReset: true)
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
    
    // MARK: - Function List

    /// Whether the reusable panel is currently on screen. Menu validation uses
    /// this to keep the View item's checkmark in step with the window.
    var isFunctionListVisible: Bool {
        functionListController?.window?.isVisible ?? false
    }

    /// View > Function List. The item is nil-targeted so this method is both
    /// the action and (through `validateMenuItem`) the enabled state.
    @objc func toggleFunctionList(_ sender: Any?) {
        guard tabStore.selectedDocument != nil else { return }

        if let controller = functionListController, controller.window?.isVisible == true {
            controller.close()
            return
        }

        let controller = functionListController ?? makeFunctionListController()
        // Always rebuild on open: the panel may have been closed while the
        // document changed, and a one-shot refresh is cheaper than keeping it
        // live in the background.
        controller.update(document: tabStore.selectedDocument)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusTable()
    }

    /// Function List menu validation: no document means no outline.
    func canShowFunctionList() -> Bool {
        tabStore.selectedDocument != nil
    }

    /// Moves the editor to `symbol` and highlights its name range. This is the
    /// same selection + scroll path Find in Files uses; the range comes from
    /// the model untouched and is only clamped for safety.
    func navigateToSymbol(_ symbol: FunctionSymbol) {
        guard let editor = editorContainer else { return }
        let length = (editor.textView.string as NSString).length
        guard symbol.range.location != NSNotFound,
              symbol.range.location <= length else { return }
        let clamped = NSRange(location: symbol.range.location,
                              length: min(symbol.range.length,
                                          length - symbol.range.location))
        // Open any collapsed ancestor fold first: otherwise Fold All would
        // leave the caret on a hidden range and the symbol line would not be
        // visible when we scroll to it.
        editor.reveal(location: clamped.location)
        editor.textView.setSelectedRange(clamped)
        editor.textView.scrollRangeToVisible(clamped)
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(editor.textView)
    }

    private func makeFunctionListController() -> FunctionListWindowController {
        let controller = FunctionListWindowController()
        controller.onSelectSymbol = { [weak self] symbol in
            self?.navigateToSymbol(symbol)
        }
        functionListController = controller
        return controller
    }

    /// Coalesced rebuild for keystroke and programmatic-edit notifications.
    /// Does nothing while the panel is hidden, so the model's regex scan only
    /// runs when its output can be seen.
    private func scheduleFunctionListUpdate() {
        guard isFunctionListVisible else { return }
        functionListRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isFunctionListVisible else { return }
            self.functionListController?.update(document: self.tabStore.selectedDocument)
        }
        functionListRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Immediate rebuild used by tab switches and language changes. The panel
    /// controller itself skips the work when the text/language are unchanged,
    /// so this cannot double-scan the same buffer.
    private func refreshFunctionListImmediately() {
        functionListRefreshWorkItem?.cancel()
        functionListRefreshWorkItem = nil
        guard isFunctionListVisible else { return }
        functionListController?.update(document: tabStore.selectedDocument)
    }

    // MARK: - Run command

    /// Single reusable Run… panel. The Run menu item is nil-targeted, so this
    /// controller owns both the action and the no-document validation.
    private var runCommandController: RunCommandWindowController?

    /// Run > Run… (F5). The panel itself is display-only: it never writes to
    /// the document or its undo stack, it only reads the current file path and
    /// caret line to fill `$(...)` placeholders.
    @objc func showRunCommandDialog(_ sender: Any?) {
        guard canRunCommand() else { return }
        let controller = runCommandPanel()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Lazily creates (and then always returns) the one Run… panel. Internal so
    /// app tests can assert the single-instance contract without showing it.
    func runCommandPanel() -> RunCommandWindowController {
        if let runCommandController { return runCommandController }

        let controller = RunCommandWindowController()
        // Resolved on every Run press against the tab that is selected then.
        controller.contextProvider = { [weak self] in
            self?.currentCommandContext() ?? ExternalCommandContext()
        }
        runCommandController = controller
        return controller
    }

    /// The placeholder context for the selected document at this instant.
    /// Uses `LineIndex` like the status bar, so `$(CURRENT_LINE)` matches the
    /// Ln label; an untitled buffer simply has no file path.
    func currentCommandContext() -> ExternalCommandContext {
        guard let doc = tabStore.selectedDocument else { return ExternalCommandContext() }
        let caret = editorContainer?.textView.selectedRange.location ?? 0
        return RunCommandWindowController.context(for: doc, caretLocation: caret)
    }

    /// Run… needs a document; the panel's placeholders are defined relative to
    /// one, and validation disables the menu item with none open.
    func canRunCommand() -> Bool {
        tabStore.selectedDocument != nil
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

    /// Reloads a clean file-backed document's buffer from disk through the
    /// shared storage, making the on-disk text the clean undoable baseline.
    /// Returns true when a reload actually happened (on-disk text differed from
    /// the in-memory buffer); the caller decides how to surface it.
    private func reloadDocument(_ doc: DocumentModel, from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              // Same decode as openFile: the document's own encoding, with a
              // leading BOM stripped, so UTF-16/CP1252 files reload correctly.
              let text = EncodingDetective.decodeForEditing(data, as: doc.encoding),
              text != doc.text else { return false }
        doc.keepsBOM = EncodingDetective.detectBOM(of: data) != nil
        // Reload through the shared buffer: the visible editor updates
        // immediately and the reload stays undoable. reloadText also makes
        // the on-disk text the clean baseline in the same notification.
        doc.reloadText(text)
        return true
    }

    /// Internal for app tests: exercises the same watcher path the timer runs.
    func checkExternalChanges() {
        for doc in allPanes.flatMap({ $0.tabStore.documents }) {
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

            if doc.unsavedChanges {
                // Dirty buffer: keep the user's edits. setModified(true) used
                // to stand here, but it is a no-op once the document is
                // already dirty. Record the conflict explicitly instead and
                // refresh the chrome so the tab keeps showing its dirty state.
                doc.noteExternalChange()
                NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard reloadDocument(doc, from: URL(fileURLWithPath: path)) else { continue }
            if allPanes.contains(where: { $0.tabStore.selectedDocument === doc }) {
                updateEditor(forceRebind: true)
            }
        }
    }

    // MARK: - View

    /// View > Fold All. Nil-targeted so menu validation can disable it when
    /// there is no document or nothing foldable. It dispatches through
    /// ``performCommand(identifier:)`` so the action is macro-recorded like any
    /// other command.
    @objc func foldAll(_ sender: Any?) {
        performCommand(identifier: "fold-all")
    }

    /// View > Unfold All. Recorded through the same capture point as Fold All.
    @objc func unfoldAll(_ sender: Any?) {
        performCommand(identifier: "unfold-all")
    }

    /// Both fold-all commands require an open document with at least one
    /// foldable range; plain text has nothing to collapse or expand.
    func canFoldAll() -> Bool {
        tabStore.selectedDocument != nil && (editorContainer?.hasFoldableRanges ?? false)
    }

    func canUnfoldAll() -> Bool {
        canFoldAll()
    }

    /// View > Word Wrap. Routes through the registry so the toggle is recorded
    /// while a macro is being captured.
    func toggleWordWrap() {
        performCommand(identifier: "toggle-word-wrap")
    }
    
    func zoomIn() {
        editorContainer?.adjustZoom(byPoints: 1)
    }
    
    func zoomOut() {
        editorContainer?.adjustZoom(byPoints: -1)
    }
    
    func resetZoom() {
        editorContainer?.resetZoom()
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
        updateEditor(forceRebind: true)
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

    /// Encoding > Line Endings: retarget the bytes the next save writes. The
    /// buffer stays LF-only, so the change is not a text edit; the document's
    /// dirty chrome is refreshed explicitly.
    func setEOL(_ eol: String) {
        guard let doc = tabStore.selectedDocument else { return }
        // "Convert to" line endings only retargets the next save: the LF-only
        // buffer is untouched, so there is no text notification to observe.
        // Refresh the dirty chrome explicitly, exactly like Convert to
        // encoding, or the tab dot, window edited flag and scheduled session
        // write would all miss the new pending conversion.
        doc.convertEOL(to: eol)
        NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
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
        if command.viewExecute != nil {
            return canPerformViewCommand(identifier)
        }
        let state = DocumentState(text: doc.text,
                                  selection: editor.textView.selectedRange,
                                  bookmarkState: doc.bookmarkState)
        if let result = commandRegistry.execute(identifier, on: state), command.documentExecute != nil {
            // Bookmark commands can change only the bookmarks or only the
            // selection; compare the whole state so those are not reported as
            // no-ops.
            return result != state
        }
        let result = command.execute(doc.text, editor.textView.selectedRange)
        return result.text != doc.text
    }

    /// View commands are only applicable when the live editor can service
    /// their hook: folding needs foldable ranges, wrapping only needs an open
    /// document. The identifiers mirror ``CommandRegistry/defaultViewCommands``.
    private func canPerformViewCommand(_ identifier: String) -> Bool {
        switch identifier {
        case "fold-all": return canFoldAll()
        case "unfold-all": return canUnfoldAll()
        case "toggle-word-wrap": return editorContainer != nil
        default: return false
        }
    }

    /// Runs a registry command against the selected document.
    ///
    /// The command receives the full ``DocumentState`` (text, selection and
    /// bookmarks) so line edits and bookmark commands share one path. A text
    /// change is applied as one `DocumentModel` replacement on the document's
    /// undo stack; bookmark changes go back to the document and the editor
    /// container so the gutter markers update immediately.
    ///
    /// View-only commands (fold-all/unfold-all/toggle-word-wrap) take the same
    /// recording path but execute through ``EditorCommandContext`` against the
    /// live editor, because their effect is not part of the document text.
    @discardableResult
    func performCommand(identifier: String, parameter: String? = nil) -> Bool {
        guard let editor = editorContainer,
              let doc = tabStore.selectedDocument,
              let command = commandRegistry.command(for: identifier) else {
            return false
        }

        if command.viewExecute != nil {
            // The single macro capture point, view-command path. Recording
            // happens before execution, matching the text-command path.
            macroRecorder.record(identifier, parameter: parameter)
            return commandRegistry.executeView(identifier,
                                               context: editorCommandContext(for: editor)) ?? false
        }

        guard let result = commandResult(identifier: identifier,
                                         parameter: parameter,
                                         doc: doc,
                                         editor: editor) else {
            return false
        }

        // The single macro capture point: every command that actually runs
        // through the registry is appended while recording. Replay never calls
        // back into here — `MacroModel.replay` runs each step through the
        // registry directly and the app applies one final result — so playing a
        // macro cannot re-record its own steps.
        macroRecorder.record(identifier, parameter: parameter)

        return applyCommandResult(result, to: doc, editor: editor)
    }

    /// Installs the live-editor hooks a view-only command needs.
    ///
    /// The closures read the current editor at execution time (not at definition
    /// time), and report whether anything actually changed.
    private func editorCommandContext(for editor: EditorContainer) -> EditorCommandContext {
        EditorCommandContext(
            foldAll: { editor.foldAll() > 0 },
            unfoldAll: { editor.unfoldAll() > 0 },
            toggleWordWrap: { editor.setWordWrapEnabled(!editor.isWordWrapEnabled) }
        )
    }

    /// Resolves a registry command against the selected document's live state,
    /// passing the macro-style parameter when the command accepts one.
    private func commandResult(identifier: String,
                               parameter: String?,
                               doc: DocumentModel,
                               editor: EditorContainer) -> DocumentState? {
        let state = DocumentState(text: doc.text,
                                  selection: editor.textView.selectedRange,
                                  bookmarkState: doc.bookmarkState)
        guard let command = commandRegistry.command(for: identifier) else { return nil }
        if let parameter, let makeAction = command.parameterizedExecute {
            let result = makeAction(parameter)(state.text, state.selection)
            return DocumentState(text: result.text,
                                 selection: result.selection,
                                 bookmarkState: state.bookmarkState)
        }
        return commandRegistry.execute(identifier, on: state)
    }

    /// Applies a command/replay result to the document as one undoable edit.
    ///
    /// Shared by ``performCommand(identifier:parameter:)`` and macro playback so
    /// a replayed macro lands on the same per-document undo stack as a single
    /// command: one undo restores the pre-command text, selection and bookmarks.
    @discardableResult
    private func applyCommandResult(_ result: DocumentState,
                                    to doc: DocumentModel,
                                    editor: EditorContainer) -> Bool {
        let original = doc.text
        var didChange = false

        if result.text != original {
            // Apply the smallest replacement so bookmark remapping sees a
            // meaningful edit instead of a whole-buffer rewrite, and the whole
            // command stays a single undo step.
            if let change = MultiCaretEditing.change(from: original, to: result.text) {
                doc.replaceCharacters(in: change.range, with: change.replacement)
            }
            // Defensive fallback: the diff must reproduce the command's text.
            if doc.text != result.text {
                doc.replaceAllText(with: result.text)
            }
            didChange = true
        }

        if result.bookmarkState != doc.bookmarkState {
            doc.bookmarkState = result.bookmarkState
            editor.applyBookmarkState(result.bookmarkState)
            didChange = true
        }

        let textLength = (doc.text as NSString).length
        let location = min(max(0, result.selection.location), textLength)
        let length = min(max(0, result.selection.length), textLength - location)
        let restored = NSRange(location: location, length: length)
        if editor.textView.selectedRange != restored {
            editor.textView.setSelectedRange(restored)
            editor.textView.scrollRangeToVisible(restored)
            didChange = true
        }

        guard didChange else { return false }

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

    /// First-responder entry point for the bookmark group of the Text menu.
    ///
    /// It shares ``performCommand(identifier:)`` with the line-editing items so
    /// both groups run through the same ``DocumentState`` path; the separate
    /// selector only keeps the menu groups distinguishable for validation and
    /// for callers that iterate the line-editing items.
    @objc func performBookmarkCommand(withIdentifier sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let identifier = item.representedObject as? String else { return }
        performCommand(identifier: identifier)
    }

    // MARK: - Macros

    /// Macro menu toggle: starts a fresh recording, or stops the current one.
    @objc func toggleMacroRecording(_ sender: Any?) {
        if macroRecorder.isRecording {
            stopMacroRecording()
        } else {
            startMacroRecording()
        }
    }

    /// Begins recording. Commands run through ``performCommand`` from now on
    /// become the macro's steps; a previous recording is discarded (the same
    /// Notepad++ behaviour of starting over).
    func startMacroRecording(name: String = "Macro") {
        macroRecorder.startRecording(name: name)
        flashStatus("Recording macro…")
    }

    /// Stops recording and makes the result the current "last macro".
    func stopMacroRecording() {
        guard macroRecorder.isRecording else { return }
        macroRecorder.stopRecording()
        lastMacro = macroRecorder
        flashStatus(macroRecorder.isEmpty
                    ? "Macro recorded with no steps"
                    : "Macro recorded: \(macroRecorder.stepCount) step\(macroRecorder.stepCount == 1 ? "" : "s")")
    }

    /// Macro > Stop Recording. Separate selector so the menu item can be
    /// validated against the live recording state.
    @objc func stopRecordingMacro(_ sender: Any?) {
        stopMacroRecording()
    }

    /// Macro > Play Last Macro.
    @objc func playLastMacro(_ sender: Any?) {
        guard let macro = lastMacro else { return }
        playMacro(macro)
    }

    /// Macro > Play Macro > <saved name>. The saved name rides in
    /// `representedObject`, so one action covers every saved macro.
    @objc func playSavedMacro(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let macro = MacroStore.macro(named: name) else { return }
        playMacro(macro)
    }

    /// Macro > Save Recording As…: names the current recording and persists it.
    @objc func saveRecordingAs(_ sender: Any?) {
        guard !macroRecorder.isEmpty else { return }
        guard let name = promptForMacroName() else { return }
        do {
            try saveRecording(named: name)
        } catch {
            showError("Failed to save macro: \(error.localizedDescription)")
        }
    }

    /// Persists the current recording under `name`, replacing any saved macro
    /// with that name. Returns the saved macro, or nil when there is nothing to
    /// save. Exposed separately from the prompt so tests can save headlessly.
    @discardableResult
    func saveRecording(named name: String) throws -> MacroModel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !macroRecorder.isEmpty else { return nil }

        var macro = macroRecorder
        macro.name = trimmed
        try MacroStore.set(macro)
        macroRecorder.name = trimmed
        lastMacro = macro
        flashStatus("Saved macro “\(trimmed)”")
        return macro
    }

    /// Macro > Delete Macro > <saved name>.
    @objc func deleteMacro(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try MacroStore.remove(named: name)
            flashStatus("Deleted macro “\(name)”")
        } catch {
            showError("Failed to delete macro: \(error.localizedDescription)")
        }
    }

    /// Replays `macro` through the registry and applies the final document
    /// state as ONE undoable edit via the shared command apply path.
    ///
    /// Replay itself is pure (``MacroModel/replay(using:text:selection:)``);
    /// skipped steps are reported in a transient status flash and do not stop
    /// the remaining steps, matching the Kit model's contract. View-only steps
    /// (`fold-all`, `unfold-all`, `toggle-word-wrap`) are recorded like any
    /// other command but have no text effect, so replay reports them as
    /// no-change skips; restoring view state is outside the document replay
    /// contract.
    @discardableResult
    func playMacro(_ macro: MacroModel) -> Bool {
        guard !macro.isEmpty,
              let editor = editorContainer,
              let doc = tabStore.selectedDocument else { return false }

        let replay = macro.replay(using: commandRegistry,
                                  text: doc.text,
                                  selection: editor.textView.selectedRange)
        lastMacro = macro

        let result = DocumentState(text: replay.text,
                                   selection: replay.selection,
                                   bookmarkState: doc.bookmarkState)
        let applied = applyCommandResult(result, to: doc, editor: editor)

        if replay.skippedCount > 0 {
            let total = replay.stepResults.count
            flashStatus("Macro “\(macro.name)”: \(replay.skippedCount) of \(total) step\(total == 1 ? "" : "s") skipped")
        } else if applied {
            flashStatus("Played macro “\(macro.name)”")
        }
        return applied
    }

    // MARK: - Macro menu validation

    /// Only a non-empty recording can be saved.
    func canSaveMacroRecording() -> Bool { !macroRecorder.isEmpty }

    /// A last macro needs steps and an open document to replay against.
    func canPlayLastMacro() -> Bool {
        tabStore.selectedDocument != nil && !(lastMacro?.isEmpty ?? true)
    }

    /// A saved macro can be played once it exists, has steps, and a document
    /// is open. Reads the store, so the menu reflects macros.json exactly.
    func canPlaySavedMacro(named name: String) -> Bool {
        guard tabStore.selectedDocument != nil,
              let macro = MacroStore.macro(named: name) else { return false }
        return !macro.isEmpty
    }

    /// Saved macros can be deleted even when they are empty.
    func canDeleteMacro(named name: String) -> Bool {
        MacroStore.macro(named: name) != nil
    }

    /// Runs the save prompt. Cancelling or entering a blank name returns nil so
    /// the caller can leave the recording untouched.
    private func promptForMacroName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Macro"
        alert.informativeText = "Name this macro so it appears in the Macro menu."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = macroRecorder.name
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Transient one-line status message in the window subtitle.
    ///
    /// Reports macro progress and per-step skips on the window subtitle for three
    /// seconds; a later flash cancels the pending clear and replaces the text.
    func flashStatus(_ message: String) {
        guard let window = mainWindow ?? view.window else { return }
        statusFlashWorkItem?.cancel()
        window.subtitle = message
        let item = DispatchWorkItem { [weak window] in
            window?.subtitle = ""
        }
        statusFlashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    // MARK: - Tools

    /// Hash algorithms offered by the Tools menu. The raw value is both the
    /// menu title and the `representedObject`, so one first-responder action
    /// covers every algorithm and the menu builder stays data-driven.
    enum HashAlgorithm: String, CaseIterable {
        case md5 = "MD5"
        case sha1 = "SHA-1"
        case sha256 = "SHA-256"

        var title: String { rawValue }

        /// Registry command implementing this algorithm.
        var commandIdentifier: String {
            switch self {
            case .md5: return "hash-md5"
            case .sha1: return "hash-sha1"
            case .sha256: return "hash-sha256"
            }
        }

        /// Lowercase hexadecimal digest of the UTF-8 text, as HashKit returns.
        func digest(of text: String) -> String {
            switch self {
            case .md5: return HashKit.md5(text)
            case .sha1: return HashKit.sha1(text)
            case .sha256: return HashKit.sha256(text)
            }
        }
    }

    /// Date/time formats offered by Tools > Insert Date/Time. The short styles
    /// follow the locale (via DateTimeInsert); the full entry inserts a
    /// sortable, unambiguous date followed by the time of day.
    enum DateTimeStyle: String, CaseIterable {
        case shortDate = "Short Date"
        case shortTime = "Short Time"
        case fullDateTime = "Full Date+Time"

        var title: String { rawValue }

        /// Registry command implementing this style.
        var commandIdentifier: String {
            switch self {
            case .shortDate: return "insert-date"
            case .shortTime: return "insert-time"
            case .fullDateTime: return "insert-datetime"
            }
        }

        func string(from date: Date) -> String {
            switch self {
            case .shortDate: return DateTimeInsert.shortDate(date)
            case .shortTime: return DateTimeInsert.shortTime(date)
            case .fullDateTime:
                return DateTimeInsert.formatted(date, pattern: "yyyy-MM-dd HH:mm:ss")
            }
        }
    }

    /// Tools > MD5 / SHA-1 / SHA-256.
    ///
    /// The digest is computed by the registry (`hash-*` group); this action only
    /// maps the menu's legacy raw value to that identifier. The registry path
    /// digests the selection when there is one and the whole buffer otherwise,
    /// then inserts the digest at the caret as one undoable edit.
    @objc func insertHashDigest(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let algorithm = HashAlgorithm(rawValue: rawValue) else { return }
        performCommand(identifier: algorithm.commandIdentifier)
    }

    /// Tools > Insert Date/Time. The registry formats the timestamp when the
    /// command executes, so replay inserts a fresh value.
    @objc func insertDateTime(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = DateTimeStyle(rawValue: rawValue) else { return }
        performCommand(identifier: style.commandIdentifier)
    }

    /// Both Tools groups need an open document; validation funnels through
    /// this so a newly added item cannot forget the no-document guard.
    func canInsertToolOutput() -> Bool {
        tabStore.selectedDocument != nil
    }

    // MARK: - Line operations

    /// Bulk line operations now live in `CommandRegistry` as the
    /// `lineOpCommands` group, so they record/replay and can take keybinding
    /// overrides. These wrappers keep the existing controller API for callers
    /// and tests while routing through the same capture point.
    func sortLinesAscending() { performCommand(identifier: "sort-lines-ascending") }
    func sortLinesDescending() { performCommand(identifier: "sort-lines-descending") }
    func removeDuplicateLines() { performCommand(identifier: "remove-duplicate-lines") }
    func removeBlankLines() { performCommand(identifier: "remove-blank-lines") }
    
    func setLanguage(_ lang: Language) {
        if let doc = tabStore.selectedDocument {
            doc.setLanguage(lang.rawValue)
            // Force one full reset so colours from the previous language do not
            // linger outside the viewport.
            docThemeNames.removeValue(forKey: doc.id)
        }
        updateEditor(forceRebind: true)
    }
    
    // MARK: - Session
    
    func saveSession() {
        // The editors and every document share their buffers, so untitled
        // (never-saved-to-disk) edits are already in the tab stores. Capture
        // each visible tab's caret/scroll/wrap/zoom first: tab switches
        // capture on unbind, but the tab on screen may have moved since.
        captureSessionState()
        try? SessionStore.save(sessionSnapshot())
    }

    /// Captures the live caret/scroll/wrap/zoom of every visible tab. The quit
    /// path and a closing window both use it so the persisted session matches
    /// what is on screen. Cheap: one state copy per pane.
    func captureSessionState() {
        for pane in allPanes {
            pane.editor.captureEditorState()
        }
    }

    /// Coalesced write used by the edit notifications.
    private func scheduleSessionSave() {
        // A second window writing its own tabs would replace the primary
        // window's session. The app delegate merges every window instead.
        guard !isAdditionalWindow else { return }
        SessionStore.scheduleSave(sessionSnapshot())
    }

    /// One snapshot for the existing session schema, which stores a single tab
    /// array and selected index.
    ///
    /// Serialized here, on the main thread, so `SessionStore`'s write queue only
    /// ever sees finished dictionaries and never reads a live `NSTextStorage`.
    ///
    /// TODO: persist the split state itself (whether group 2 is open and which
    /// documents belong to which group). That needs a schema addition in
    /// SessionStore; until then both groups' documents are merged so closing
    /// the app cannot drop a buffer from either group. On relaunch every tab
    /// reopens in group 1.
    func sessionSnapshot() -> SessionStore.Snapshot {
        let documents = primaryPane.tabStore.documents
            + (secondaryPane?.tabStore.documents ?? [])
        return SessionStore.Snapshot(tabs: documents.map { $0.toSessionData() },
                                     selectedIndex: primaryPane.tabStore.selectedIndex)
    }
    
    // MARK: - Error
    
    /// Drops the controller's strong reference to its window so a closed
    /// additional window can deallocate: the window retains this controller as
    /// its content view controller, so keeping `mainWindow` strong would leave
    /// the pair in a cycle after the app delegate forgets the controller.
    func releaseWindowReference() {
        mainWindow = nil
    }

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
        if menuItem.action == #selector(MainWindowController.performCommand(withIdentifier:))
            || menuItem.action == #selector(MainWindowController.performBookmarkCommand(withIdentifier:)) {
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
        if menuItem.action == #selector(MainWindowController.insertHashDigest(_:))
            || menuItem.action == #selector(MainWindowController.insertDateTime(_:)) {
            return canInsertToolOutput()
        }
        if menuItem.action == #selector(MainWindowController.toggleMacroRecording(_:)) {
            // A checkmark mirrors the recording state; the item stays enabled so
            // the same entry can stop the recording it started.
            menuItem.state = isRecordingMacro ? .on : .off
            return true
        }
        if menuItem.action == #selector(MainWindowController.stopRecordingMacro(_:)) {
            return isRecordingMacro
        }
        if menuItem.action == #selector(MainWindowController.playLastMacro(_:)) {
            return canPlayLastMacro()
        }
        if menuItem.action == #selector(MainWindowController.playSavedMacro(_:)) {
            guard let name = menuItem.representedObject as? String else { return false }
            return canPlaySavedMacro(named: name)
        }
        if menuItem.action == #selector(MainWindowController.saveRecordingAs(_:)) {
            return canSaveMacroRecording()
        }
        if menuItem.action == #selector(MainWindowController.deleteMacro(_:)) {
            guard let name = menuItem.representedObject as? String else { return false }
            return canDeleteMacro(named: name)
        }
        if menuItem.action == #selector(MainWindowController.toggleFunctionList(_:)) {
            menuItem.state = isFunctionListVisible ? .on : .off
            return canShowFunctionList()
        }
        if menuItem.action == #selector(MainWindowController.showRunCommandDialog(_:)) {
            return canRunCommand()
        }
        if menuItem.action == #selector(MainWindowController.foldAll(_:)) {
            return canFoldAll()
        }
        if menuItem.action == #selector(MainWindowController.unfoldAll(_:)) {
            return canUnfoldAll()
        }
        if menuItem.action == #selector(MainWindowController.toggleSplitView(_:)) {
            menuItem.state = isSplitViewOpen ? .on : .off
            // Open/closed is a window capability, not a document command; keep
            // it enabled while open even if both groups happen to be empty so
            // the user can always close the split.
            return view.window != nil && (isSplitViewOpen || primaryPane.tabStore.selectedDocument != nil)
        }
        if menuItem.action == #selector(MainWindowController.toggleSynchronizeScrolling(_:)) {
            menuItem.state = synchronizeScrolling ? .on : .off
            return canSynchronizeScrolling()
        }
        if menuItem.action == #selector(MainWindowController.moveToOtherView(_:)) {
            return canMoveToOtherView()
        }
        if menuItem.action == #selector(MainWindowController.showDocumentSwitcher(_:)) {
            return canShowDocumentSwitcher()
        }
        if menuItem.action == #selector(MainWindowController.printDocument(_:)) {
            return canPrintDocument()
        }
        return true
    }
}

// MARK: - NSTextViewDelegate

extension MainWindowController: NSTextViewDelegate {
    func undoManager(for textView: NSTextView) -> UndoManager? {
        // Each group has its own bound document, so undo must resolve against
        // the text view that asked rather than whichever group is focused.
        if let pane = pane(containing: textView) {
            return pane.boundDocument?.undoManager ?? textView.undoManager
        }
        return textView.undoManager
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
        // derived from that buffer, so only the affected tab dots need
        // refreshing. No reload: that used to rebuild every tab button and
        // compare every document's full text on each keystroke.
        refreshDirtyIndicators()
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
