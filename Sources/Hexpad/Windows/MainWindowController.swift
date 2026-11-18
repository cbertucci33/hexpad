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

    // MARK: - Window modes (V19e)

    /// N++ View menu parity. Always on Top is a plain window-level state.
    /// Post-It and Distraction Free hide window chrome and are expressed as a
    /// mode so `updateLayout` has one authority for bar heights and margins.
    /// Both are per-window and reset on launch (nothing is persisted).
    enum ChromeMode {
        case normal
        case postIt
        case distractionFree
    }

    private(set) var chromeMode: ChromeMode = .normal
    private(set) var isAlwaysOnTop = false

    /// Post-It chrome captured on entry, restored verbatim on exit. The saved
    /// frame is reapplied after the toolbar/style-mask edits, which otherwise
    /// make AppKit resize the window to keep the content area stable.
    private var savedWindowChrome: (toolbar: NSToolbar?,
                                    titleVisibility: NSWindow.TitleVisibility,
                                    titlebarAppearsTransparent: Bool,
                                    hadFullSizeContentView: Bool,
                                    frame: NSRect)?

    /// Watches the user leaving full screen while in Distraction Free (Escape or
    /// the green button), so the mode cannot outlive the full-screen state it
    /// depends on.
    private var windowModeObserver: NSObjectProtocol?

    private var mainWindow: MainWindow?
    var recentFilesManager: RecentFilesManager?

    /// Menu/keybinding layer for the editor commands. The registry itself is
    /// Kit-owned; this controller only resolves and applies its commands to the
    /// selected document. It is one instance for the whole window, so its
    /// line-comment prefix is retargeted whenever the focused document's
    /// language changes (see ``updateEditor(forceRebind:)``).
    private var commandRegistry = CommandRegistry.default

    /// The line-comment prefix for `document`'s language, read from its lexer
    /// definition's comment metadata. Unknown or metadata-less languages keep
    /// the registry's `//` default.
    private func commentPrefix(for document: DocumentModel?) -> String {
        CommentPrefixResolver.lineCommentPrefix(for: document)
    }

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
    /// Exposed for app tests (chrome-mode layout assertions); nothing outside
    /// this controller may mutate it.
    private(set) var statusBar: StatusBar?
    /// Exposed for app tests (find-bar counts/highlight behaviour) and refreshed
    /// only through `refreshChrome`'s injected refs.
    private(set) var findBar: FindBar?
    /// Search > Incremental Search (Cmd+I). A separate bar with its own query,
    /// deliberately isolated from `findBar`'s field/history/match list.
    private(set) var incrementalSearchBar: IncrementalSearchBar?
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
    /// Reusable Open Folder as Workspace listing panel. v1 is a flat recursive
    /// list; tree expansion, watching and persistence are deferred.
    private var workspacePanelController: WorkspacePanelController?
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

    /// Most-recently-used tab order for the focused group. Document ids (not
    /// indices) so closing or reordering tabs cannot silently retarget an
    /// entry. Used only when `preferences.mruTabSwitching` is on.
    private var mruOrder = MRUOrder<UUID>()
    
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
        if let observer = windowModeObserver {
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
        // Token style ranges are offsets, so every character edit must move
        // them: typing, programmatic edits, undo and multi-caret all reach this
        // storage notice. Watching the storage (rather than only the text
        // delegate) keeps the ranges aligned with the buffer the model owns.
        NotificationCenter.default.addObserver(self, selector: #selector(handleTokenStyleEdit(_:)), name: NSTextStorage.didProcessEditingNotification, object: nil)
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
        // Distraction Free relies on the system full-screen transition. If the
        // user leaves full screen some other way (Escape, green button), the
        // mode must not stay on with chrome hidden in a windowed frame.
        windowModeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowDidExitFullScreen(notification)
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

            if previous.minimapVisible != preferences.minimapVisible {
                // The document map is global, not per document, so every pane
                // picks up the change immediately (including the unfocused
                // split group).
                pane.editor.setMinimapVisible(preferences.minimapVisible)
            }

            if previous.showWhitespace != preferences.showWhitespace
                || previous.showEOL != preferences.showEOL
                || previous.showIndentGuide != preferences.showIndentGuide
                || previous.tabSize != preferences.tabSize {
                // Show Symbol options are global and viewport-rendered, so the
                // same push covers every tab and the unfocused split group.
                pane.editor.setShowSymbols(showWhitespace: preferences.showWhitespace,
                                           showEOL: preferences.showEOL,
                                           showIndentGuide: preferences.showIndentGuide,
                                           tabSize: preferences.tabSize)
            }
        }

        if previous.theme != preferences.theme {
            for pane in panesFocusedLast {
                if let doc = pane.tabStore.selectedDocument {
                    rehighlightAll(in: pane.editor, document: doc)
                }
            }
        }

        // Tab bar chrome is applied live: hiding reserves no layout slot, and
        // the interaction/label options take effect on the next reload.
        if previous.showTabBar != preferences.showTabBar {
            updateLayout()
        }
        if previous.showTabBar != preferences.showTabBar
            || previous.lockTabBar != preferences.lockTabBar
            || previous.doubleClickTabCloses != preferences.doubleClickTabCloses
            || previous.maxTabLabelLength != preferences.maxTabLabelLength {
            refreshTabBar()
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

    /// Keeps token style ranges aligned with character edits.
    ///
    /// Mirrors ``EditorContainer``'s bookmark remapping: NSTextStorage reports
    /// the post-edit range plus the length delta, which gives the pre-edit
    /// ``FoldTextEdit``. A whole-buffer replacement has no meaningful range
    /// mapping, so the styles are revalidated (clipped/dropped) instead.
    @objc private func handleTokenStyleEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }

        let documents = allPanes.flatMap { $0.tabStore.documents }
        guard let doc = documents.first(where: { $0.textStorage === storage }),
              !doc.editorState.tokenStyleState.isEmpty else { return }

        let insertedLength = storage.editedRange.length
        let replacedLength = max(0, insertedLength - storage.changeInLength)
        let edit = FoldTextEdit(location: storage.editedRange.location,
                                replacedLength: replacedLength,
                                insertedLength: insertedLength)
        let oldLength = storage.length - storage.changeInLength

        if edit.location == 0, edit.replacedLength > 0, edit.replacedLength >= oldLength {
            doc.editorState.tokenStyleState = doc.editorState.tokenStyleState
                .revalidated(in: doc.text)
        } else {
            doc.editorState.tokenStyleState = doc.editorState.tokenStyleState
                .remapped(from: doc.text, for: edit, to: doc.text)
        }

        if let pane = allPanes.first(where: { $0.editor.textView.textStorage === storage }) {
            pane.editor.textView.applyTokenStyles(doc.editorState.tokenStyleState,
                                                  theme: theme(for: pane.editor))
        }
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
        status.onToggleOverwriteMode = { [weak self] in
            self?.toggleOverwriteMode()
        }
        
        let find = FindBar()
        view.addSubview(find)
        findBar = find
        find.tabStoreRef = primaryPane.tabStore
        find.editorRef = primaryPane.editor
        find.setupObservers()

        let incremental = IncrementalSearchBar()
        incremental.onClose = { [weak self] in
            self?.incrementalSearchBarDidHide()
        }
        view.addSubview(incremental)
        incrementalSearchBar = incremental

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
        pane.tabBar.onNewTabRequested = { [weak self] in self?.addNewTab() }
        pane.tabBar.contextMenuProvider = { [weak self] index in
            guard let self else { return nil }
            // Every action and every validation reads the focused group's
            // activePane store. Focus this pane *before* building the menu so
            // a right-click in the other split group acts on that tab.
            self.focusGroup(group)
            return self.buildTabContextMenu(for: index)
        }
    }

    /// Notepad++'s tab context menu, built from the very same selectors and
    /// targets the File/View menus use. Delegate actions are explicitly
    /// targeted so `HexpadAppDelegate.validateMenuItem` (close scopes,
    /// containing-folder) owns their grey-out; controller actions stay
    /// nil-targeted so `MainWindowController.validateMenuItem` owns theirs.
    func buildTabContextMenu(for index: Int,
                             delegate: HexpadAppDelegate? = nil) -> NSMenu {
        let delegate = delegate ?? (NSApp.delegate as? HexpadAppDelegate)
        // `index` identifies the clicked tab for the caller; every action
        // itself runs against the focused group's selected document.
        let menu = NSMenu(title: "Tab")

        func delegateItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = delegate
            return item
        }
        func responderItem(_ title: String, _ action: Selector) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: "")
        }

        // Close group.
        menu.addItem(delegateItem("Close Tab", #selector(HexpadAppDelegate.closeTab)))
        menu.addItem(delegateItem("Close All Tabs", #selector(HexpadAppDelegate.closeAllTabs)))
        menu.addItem(delegateItem("Close All but Active Document",
                                  #selector(HexpadAppDelegate.closeAllButActiveDocument)))
        menu.addItem(delegateItem("Close All to the Left",
                                  #selector(HexpadAppDelegate.closeAllDocumentsToLeft)))
        menu.addItem(delegateItem("Close All to the Right",
                                  #selector(HexpadAppDelegate.closeAllDocumentsToRight)))
        menu.addItem(delegateItem("Close All Unchanged",
                                  #selector(HexpadAppDelegate.closeAllUnchangedDocuments)))

        menu.addItem(.separator())

        // Save / reload / print group.
        menu.addItem(delegateItem("Save", #selector(HexpadAppDelegate.saveFile)))
        menu.addItem(delegateItem("Save As...", #selector(HexpadAppDelegate.saveAsFile)))
        menu.addItem(responderItem("Reload from Disk",
                                   #selector(MainWindowController.reloadActiveDocument(_:))))
        menu.addItem(responderItem("Print…",
                                   #selector(MainWindowController.printDocument(_:))))

        menu.addItem(.separator())

        // Open Containing Folder group, identical leaves to File menu.
        let containingItem = NSMenuItem(title: "Open Containing Folder",
                                        action: nil,
                                        keyEquivalent: "")
        let containingMenu = NSMenu(title: "Open Containing Folder")
        containingMenu.addItem(responderItem(
            "Finder", #selector(HexpadAppDelegate.openContainingFolderInFinder(_:))))
        containingMenu.addItem(responderItem(
            "Terminal", #selector(HexpadAppDelegate.openContainingFolderInTerminal(_:))))
        containingItem.submenu = containingMenu
        menu.addItem(containingItem)

        menu.addItem(.separator())

        // Move group.
        menu.addItem(responderItem("Move to Other View",
                                   #selector(MainWindowController.moveToOtherView(_:))))
        menu.addItem(responderItem("Move Tab to Start",
                                   #selector(MainWindowController.moveTabToStart(_:))))
        menu.addItem(responderItem("Move Tab to End",
                                   #selector(MainWindowController.moveTabToEnd(_:))))
        return menu
    }
    
    private func updateLayout() {
        guard let status = statusBar else { return }

        // Post-It and Distraction Free collapse the tab bar and status bar to
        // zero height: the layout slot disappears, not just the paint. The
        // views themselves are untouched apart from visibility. The Settings
        // "Show tab bar" preference collapses only the tab bar the same way.
        let chromeHidden = chromeMode != .normal
        let distractionFree = chromeMode == .distractionFree
        let tabBarVisible = !chromeHidden && preferences.showTabBar
        let tabBarHeight: CGFloat = tabBarVisible ? 32 : 0
        let statusHeight: CGFloat = chromeHidden ? 0 : 22

        // The find bar is a tool, but "only the editor" includes it while chrome
        // is hidden. Its own `isVisible` flag is preserved so leaving the mode
        // restores exactly what the user had open.
        let findVisible = !chromeHidden && (findBar?.isVisible ?? false)
        findBar?.isHidden = !findVisible
        let findHeight = findBar?.preferredHeight(for: view.bounds.width) ?? 36
        let topInset = tabBarHeight + (findVisible ? findHeight : 0)
        let height = view.bounds.height
        let width = view.bounds.width

        // Distraction Free pads the text column ~15% on each side (N++'s wide
        // margins). The inset applies to the whole content area, so a split
        // view keeps both groups side by side inside the margins.
        let horizontalInset = distractionFree ? floor(width * 0.15) : 0
        let contentX = horizontalInset
        let contentWidth = max(0, width - horizontalInset * 2)

        // The divider is one point of chrome between the two groups. Keeping
        // the single-group widths untouched when the split is closed preserves
        // the original layout math exactly.
        let dividerWidth: CGFloat = isSplitViewOpen ? 1 : 0
        let primaryWidth = isSplitViewOpen
            ? max(0, floor((contentWidth - dividerWidth) / 2))
            : contentWidth

        layoutPane(primaryPane,
                   x: contentX,
                   width: primaryWidth,
                   height: height,
                   topInset: topInset,
                   statusHeight: statusHeight,
                   tabBarHeight: tabBarHeight,
                   hidesTabBar: !tabBarVisible)

        let editorTop = height - topInset
        let editorHeight = max(editorTop - statusHeight, 100)

        if let secondary = secondaryPane {
            let x = contentX + primaryWidth + dividerWidth
            layoutPane(secondary,
                       x: x,
                       width: max(0, contentWidth - primaryWidth - dividerWidth),
                       height: height,
                       topInset: topInset,
                       statusHeight: statusHeight,
                       tabBarHeight: tabBarHeight,
                       hidesTabBar: !tabBarVisible)
            dividerView?.isHidden = false
            dividerView?.frame = NSRect(x: contentX + primaryWidth,
                                        y: statusHeight,
                                        width: dividerWidth,
                                        height: editorHeight)
        } else {
            dividerView?.isHidden = true
        }

        findBar?.frame = findVisible
            ? NSRect(x: contentX,
                     y: max(statusHeight, height - topInset),
                     width: contentWidth,
                     height: findHeight)
            : .zero

        // Incremental search floats over the focused editor's top-right corner
        // instead of reserving layout space, so opening it never reflows text.
        if let incremental = incrementalSearchBar {
            incremental.isHidden = chromeHidden || !incremental.isVisible
            if incremental.isVisible && !chromeHidden {
                let editorFrame = activePane.editor.frame
                let barWidth = min(380, max(220, editorFrame.width - 16))
                incremental.frame = NSRect(x: editorFrame.maxX - barWidth - 8,
                                           y: max(statusHeight, editorFrame.maxY - IncrementalSearchBar.preferredHeight - 6),
                                           width: barWidth,
                                           height: IncrementalSearchBar.preferredHeight)
            }
        }

        status.isHidden = chromeHidden
        status.frame = chromeHidden
            ? .zero
            : NSRect(x: 0, y: 0, width: width, height: statusHeight)
    }

    /// Lays out one group's tab bar and editor inside its horizontal slice.
    /// `hidesTabBar` zeroes the tab bar container's slot: the bar keeps its own
    /// frame so tab buttons stay correctly sized when the mode ends.
    private func layoutPane(_ pane: TabGroupPane,
                            x: CGFloat,
                            width: CGFloat,
                            height: CGFloat,
                            topInset: CGFloat,
                            statusHeight: CGFloat,
                            tabBarHeight: CGFloat,
                            hidesTabBar: Bool) {
        if hidesTabBar {
            pane.tabScrollView.frame = .zero
            pane.tabScrollView.isHidden = true
            pane.tabBar.isHidden = true
        } else {
            pane.tabScrollView.isHidden = false
            pane.tabBar.isHidden = false
            pane.tabScrollView.frame = NSRect(x: x,
                                              y: max(0, height - tabBarHeight),
                                              width: width,
                                              height: tabBarHeight)
            pane.tabBar.frame.size.height = tabBarHeight
            pane.tabBar.fitWidthToClip()
        }

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
        let doc = DocumentModel(text: "",
                                encoding: preferences.defaultEncoding,
                                eolType: preferences.defaultEOL)
        // The preference is the default for a document that has no persisted
        // editor state of its own. Restored tabs keep the state the session
        // stored; this only seeds newly created buffers. The same applies to
        // the encoding and line endings chosen in Settings > Editor.
        doc.wordWrapEnabled = preferences.wordWrap
        tabStore.addDocument(doc)
        refreshTabBar()
        noteTabActivated()
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
    
    // MARK: - Save All

    /// File > Save All. Writes every dirty file-backed document in both tab
    /// groups through the ordinary save path. Untitled buffers are skipped
    /// (saving one needs a name, so that remains a per-tab Save As); a failed
    /// write does not stop the sweep and all failures are reported afterwards.
    /// The menu item stays enabled even with nothing dirty, like N++.
    func saveAllDocuments() {
        var failures: [String] = []
        var savedAny = false

        for doc in allPanes.flatMap({ $0.tabStore.documents }) {
            guard doc.filePath != nil, doc.unsavedChanges else { continue }
            do {
                try doc.save()
                savedAny = true
            } catch {
                failures.append("\(doc.name): \(error.localizedDescription)")
            }
        }

        guard savedAny || !failures.isEmpty else { return }
        NotificationCenter.default.post(name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
        refreshTabBar()
        updateStatusBar()

        if !failures.isEmpty {
            showError("Failed to save file:\n" + failures.joined(separator: "\n"))
        }
    }

    // MARK: - Workspace

    /// File > Open Folder as Workspace…. Picks a folder and shows a flat,
    /// recursively built list of text-ish files. Double-clicking a row opens
    /// it in the focused group's editor through the normal open path.
    func openFolderAsWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder as Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let workspace: WorkspacePanelController
        if let existing = workspacePanelController {
            existing.update(rootURL: url)
            workspace = existing
        } else {
            let created = WorkspacePanelController(rootURL: url)
            created.onOpenFile = { [weak self] path in
                guard let self else { return }
                self.openFile(atPath: path)
                self.view.window?.makeKeyAndOrderFront(nil)
            }
            workspacePanelController = created
            workspace = created
        }
        workspace.showWindow(nil)
        workspace.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Reload from Disk

    /// File > Reload from Disk. Reuses the external-change reload path. A clean
    /// buffer reloads silently; a dirty one asks before discarding edits.
    /// Validation disables the item when the focused tab has no file.
    @objc func reloadActiveDocument(_ sender: Any?) {
        guard let doc = tabStore.selectedDocument,
              let url = doc.filePath else { return }

        if doc.unsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved changes to \(doc.name)?"
            alert.informativeText = "The file will be reloaded from disk and your unsaved edits will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("The file no longer exists on disk.")
            return
        }

        if !reloadDocument(doc, from: url) {
            // The on-disk text already matches the buffer. After a confirmed
            // discard that still means dropping the dirty baseline.
            doc.setModified(false)
        }

        // The explicit reload supersedes this tick's external-change signal.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date {
            seenModDates[doc.id] = modDate
        }

        refreshTabBar()
        updateEditor(forceRebind: true)
        updateStatusBar()
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
        // one into an already-processed slot.
        var queue: [(pane: TabGroupPane, doc: DocumentModel)] = []
        for pane in allPanes {
            queue.append(contentsOf: pane.tabStore.documents.reversed().map { (pane, $0) })
        }
        guard !queue.isEmpty else {
            addNewTab()
            return
        }
        closeDocumentsInOrder(queue)
    }

    /// File > Close Multiple Documents. Scope is resolved against the focused
    /// group's tab order; the sweep itself reuses the Close All prompt/close
    /// loop so each dirty document asks individually and Cancel stops the rest.
    func closeMultipleDocuments(_ scope: TabCloseScope) {
        let targets = tabStore.documents(matching: scope)
        guard !targets.isEmpty else { return }
        let pane = activePane
        closeDocumentsInOrder(targets.map { (pane, $0) })
    }

    /// Whether a Close Multiple Documents variant has anything to act on.
    func canCloseMultipleDocuments(_ scope: TabCloseScope) -> Bool {
        switch scope {
        case .unchanged:
            return tabStore.documents.contains { !$0.unsavedChanges }
        case .allButActive, .allButPinned, .toLeftOfActive, .toRightOfActive:
            return tabStore.count > 1
        }
    }

    /// Shared bulk-close sweep. Dirty docs get the same save prompt as a single
    /// close; Cancel stops the sweep and leaves the remaining tabs open.
    private func closeDocumentsInOrder(_ queue: [(pane: TabGroupPane, doc: DocumentModel)]) {
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
        noteTabActivated()
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
    ///
    /// With MRU tab switching on, "next" means the previously used tab rather
    /// than the positional neighbor. The stack is a simplification: it records
    /// activations only, so holding the chord toggles the two most recent tabs
    /// instead of cycling through every tab in usage order.
    func selectNextTab() {
        guard tabStore.count > 1 else { return }
        if preferences.mruTabSwitching,
           let current = tabStore.selectedDocument,
           let target = mruOrder.next(after: current.id),
           let index = tabStore.documents.firstIndex(where: { $0.id == target }) {
            selectTab(at: index)
            return
        }
        selectTab(at: (tabStore.selectedIndex + 1) % tabStore.count)
    }

    /// Wraps backward through the open tabs; with MRU on, it walks the stack in
    /// the other direction.
    func selectPreviousTab() {
        guard tabStore.count > 1 else { return }
        if preferences.mruTabSwitching,
           let current = tabStore.selectedDocument,
           let target = mruOrder.previous(after: current.id),
           let index = tabStore.documents.firstIndex(where: { $0.id == target }) {
            selectTab(at: index)
            return
        }
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

    /// Selects the tab at a zero-based index and moves first responder into the
    /// focused group's editor. Unlike ``selectTab(at:)`` this also focuses the
    /// editor when the requested tab is already selected, because the View > Tab
    /// items are also used to return to the buffer being edited.
    func selectNthTab(_ index: Int) {
        guard index >= 0, index < tabStore.count else { return }
        selectTab(at: index)
        view.window?.makeFirstResponder(editorContainer?.textView)
    }

    /// Handles View > Tab > 1st..9th Tab. The item tag holds the 1-based tab
    /// number, matching the Window menu's Tab 1..9 items. Named apart from the
    /// index-taking overload so the selector stays unambiguous.
    @objc func selectNthTabFromMenu(_ sender: NSMenuItem) {
        selectNthTab(sender.tag - 1)
    }

    @objc func selectFirstTab(_ sender: Any?) {
        selectNthTab(0)
    }

    @objc func selectLastTab(_ sender: Any?) {
        selectNthTab(tabStore.count - 1)
    }

    /// View > Tab > Move Tab to Start. Tab order is window chrome, not buffer
    /// state, so this deliberately skips the undo stack and the session's
    /// document payload; only the on-screen order changes.
    @objc func moveTabToStart(_ sender: Any?) {
        moveSelectedTab(to: 0)
    }

    /// View > Tab > Move Tab to End.
    @objc func moveTabToEnd(_ sender: Any?) {
        moveSelectedTab(to: tabStore.count - 1)
    }

    /// Reorders the focused group's tabs, keeping the moved document selected.
    /// `TabStore.moveDocument` preserves the order array only; the selection is
    /// an index, so it must follow the document to its new slot or the next
    /// command would act on whichever tab slid into the old index.
    private func moveSelectedTab(to destination: Int) {
        guard tabStore.count > 1 else { return }
        let source = tabStore.selectedIndex
        guard source >= 0, source != destination else { return }
        tabStore.moveDocument(from: source, to: destination)
        tabStore.selectDocument(at: destination)
        refreshTabBar()
        // The selected document is unchanged but its index moved, so the
        // FindBar and both tab bars still need the notice the drag path posts.
        postTabSelectionDidChange()
    }

    /// Window > Sort By. The menu item's `representedObject` is the sort key's
    /// raw value (`name|path|type|length|modified`) and its tag is 1 for
    /// ascending, 0 for descending. Reordering tabs is window chrome, so this
    /// deliberately skips the undo stack just like `moveSelectedTab`.
    @objc func sortDocumentsBy(_ sender: NSMenuItem) {
        guard let key = TabSortKey(rawValue: sender.representedObject as? String ?? "") else { return }
        tabStore.sortDocuments(by: key, ascending: sender.tag == 1)
        refreshTabBar()
        // Sorting changes every tab's index, including the selected document's,
        // so the FindBar and both tab bars need the same notice a move posts.
        postTabSelectionDidChange()
    }
    
    func refreshTabBar() {
        allPanes.forEach { pane in
            // Interaction and caption options are live: the bar re-reads them
            // on every reload, and the notification handler calls this path.
            pane.tabBar.lockTabBar = preferences.lockTabBar
            pane.tabBar.doubleClickTabCloses = preferences.doubleClickTabCloses
            pane.tabBar.maxTabLabelLength = preferences.maxTabLabelLength
            pane.tabBar.reloadTabs()
        }
        synchronizeMRU()
    }

    /// Keeps the MRU stack aligned with the focused store (closed tabs pruned,
    /// new tabs appended in positional order).
    private func synchronizeMRU() {
        mruOrder.synchronize(with: tabStore.documents.map(\.id))
    }

    /// Records the focused group's selected tab as most recently used.
    private func noteTabActivated() {
        synchronizeMRU()
        guard let doc = tabStore.selectedDocument else { return }
        mruOrder.touch(doc.id)
    }
    
    func updateEditor(forceRebind: Bool = false) {
        bindChangedPanes(force: forceRebind)
        // Tab switches, language changes and focus changes all land here. The
        // registry is shared across documents, so retarget its comment command
        // to the focused document's language before any command can run.
        commandRegistry.updatedLineCommentPrefix(
            commentPrefix(for: activePane.tabStore.selectedDocument)
        )
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
        incrementalSearchBar?.editorRef = pane.editor

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
        noteTabActivated()
        updateEditor()
    }

    /// Makes `group` the focused group. Find and every Tools/Text command act
    /// on the focused group's selected document, so that is the only state a
    /// focus change needs to move.
    func focusGroup(_ group: TabGroup) {
        if group == .secondary && secondaryPane == nil { return }
        guard group != focusedGroup else { return }
        // The incremental bar highlights the focused editor with temporary
        // attributes; close it while the old editor is still injected so those
        // highlights are cleared from the buffer they belong to.
        incrementalSearchBar?.hide()
        focusedGroup = group
        noteTabActivated()
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

    // MARK: - Window modes (V19e)

    private var windowForModes: NSWindow? { view.window ?? mainWindow }

    /// View > Always on Top. A window-level toggle: floating above other apps
    /// when on, ordinary level when off. Per-window and not persisted, exactly
    /// like Notepad++ (each new window starts normal).
    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        isAlwaysOnTop.toggle()
        windowForModes?.level = isAlwaysOnTop ? .floating : .normal
    }

    /// View > Post-It. Hides the title/toolbar/tab bar/status bar and keeps the
    /// window frame untouched, leaving only the editor. The menu bar stays (so
    /// this same item, or Escape, can leave the mode), and tab switching still
    /// works through the Window menu shortcuts.
    @objc func togglePostIt(_ sender: Any?) {
        applyChromeMode(chromeMode == .postIt ? .normal : .postIt)
    }

    /// View > Distraction Free Mode. Full screen plus hidden chrome plus wide
    /// text margins. Reuses the system full-screen transition behind the
    /// existing Window > Enter Full Screen item rather than reimplementing it.
    @objc func toggleDistractionFreeMode(_ sender: Any?) {
        applyChromeMode(chromeMode == .distractionFree ? .normal : .distractionFree)
    }

    /// Escape leaves Post-It, matching N++'s Post-It key. This runs only when no
    /// inner responder (find bar, incremental search, multi-caret) already
    /// consumed the key; the other modes keep their existing Escape behaviour.
    override func cancelOperation(_ sender: Any?) {
        if chromeMode == .postIt {
            applyChromeMode(.normal)
            return
        }
        super.cancelOperation(sender)
    }

    /// Single path for every mode transition. Post-It and Distraction Free are
    /// mutually exclusive: leaving a mode restores its chrome (and full-screen
    /// state) before the next one is entered, so entering one exits the other.
    /// Full screen entered independently through Window > Enter Full Screen is
    /// left alone; only Distraction Free owns that transition.
    private func applyChromeMode(_ mode: ChromeMode) {
        guard mode != chromeMode else { return }
        let window = windowForModes

        if chromeMode == .postIt {
            restorePostItChrome(on: window)
        }
        if chromeMode == .distractionFree {
            exitFullScreenIfNeeded(window)
        }

        chromeMode = mode

        switch mode {
        case .normal:
            break
        case .postIt:
            // Post-It is a windowed mode: a window already in full screen is
            // returned to its ordinary frame first (asynchronously).
            exitFullScreenIfNeeded(window)
            enterPostItChrome(on: window)
        case .distractionFree:
            enterFullScreenIfNeeded(window)
        }

        updateLayout()
    }

    private func enterFullScreenIfNeeded(_ window: NSWindow?) {
        guard let window, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func exitFullScreenIfNeeded(_ window: NSWindow?) {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// Hides the title bar controls' contents and the toolbar without dropping
    /// `.titled` (which would lose the traffic lights and window behaviours).
    /// `fullSizeContentView` lets the editor occupy the title-bar band, so the
    /// content area fills the same window frame.
    private func enterPostItChrome(on window: NSWindow?) {
        guard let window else { return }
        if savedWindowChrome == nil {
            savedWindowChrome = (window.toolbar,
                                 window.titleVisibility,
                                 window.titlebarAppearsTransparent,
                                 window.styleMask.contains(.fullSizeContentView),
                                 window.frame)
        }
        window.toolbar = nil
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Removing the toolbar changes the content layout and AppKit resizes
        // the window around it; put the frame back so Post-It keeps its size.
        if let saved = savedWindowChrome {
            window.setFrame(saved.frame, display: false)
        }
    }

    private func restorePostItChrome(on window: NSWindow?) {
        guard let window, let saved = savedWindowChrome else { return }
        window.toolbar = saved.toolbar
        if !saved.hadFullSizeContentView {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.titleVisibility = saved.titleVisibility
        window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
        window.setFrame(saved.frame, display: false)
        savedWindowChrome = nil
    }

    private func handleWindowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === windowForModes,
              chromeMode == .distractionFree else { return }
        chromeMode = .normal
        updateLayout()
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

    /// Applies the persisted font, word-wrap and document-map defaults to the
    /// bound editor.
    ///
    /// Font is a global preference and always wins. Word wrap is per document:
    /// `bind()` has already applied `editorState.wordWrapEnabled`, which is
    /// authoritative once the tab exists. Only an unbound editor uses the
    /// preference directly (and new documents are seeded from it at creation).
    /// The document map is global, so it is applied on every bind and restore
    /// without being written into any document's state.
    private func applyPreferences(to editor: EditorContainer, for document: DocumentModel?) {
        editor.setBodyFont(PreferencesApplier.resolvedFont(family: preferences.fontFamily,
                                                            size: preferences.fontSize))
        editor.setWordWrapEnabled(document?.wordWrapEnabled ?? preferences.wordWrap)
        editor.setMinimapVisible(preferences.minimapVisible)
        // Show Symbol options are global and stateless per document, so every
        // bind re-applies them without writing anything back to the tab.
        editor.setShowSymbols(showWhitespace: preferences.showWhitespace,
                              showEOL: preferences.showEOL,
                              showIndentGuide: preferences.showIndentGuide,
                              tabSize: preferences.tabSize)
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
        // Temporary-attribute backgrounds are independent of the text-storage
        // attribute rewrite below, but the theme (and the palette derived from
        // it) can change with the document, so re-apply them on every pass.
        editor.textView.applyTokenStyles(doc.editorState.tokenStyleState, theme: theme)

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

    /// Flips overwrite typing for the focused editor, driven by the status
    /// bar's INS/OVR field. Session-only UI state on the shared text view: no
    /// preference and no per-document persistence (v1 has no Insert key).
    func toggleOverwriteMode() {
        guard let editor = editorContainer else { return }
        editor.textView.isOverwriteMode.toggle()
        updateStatusBar()
        // The mode field is a label, so it never becomes first responder;
        // restoring the editor explicitly keeps the next keystroke in the
        // buffer, now in the new mode.
        view.window?.makeFirstResponder(editor.textView)
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

    // MARK: - Incremental Search (Cmd+I)

    /// Search > Incremental Search. Opens/closes the floating incremental bar
    /// over the focused editor. The bar owns its query and match list, so the
    /// main FindBar's field, history and match counter are untouched.
    @objc func toggleIncrementalSearch(_ sender: Any?) {
        guard let bar = incrementalSearchBar else { return }
        if bar.isVisible {
            hideIncrementalSearch()
        } else {
            showIncrementalSearch()
        }
    }

    private func showIncrementalSearch() {
        guard let bar = incrementalSearchBar else { return }
        bar.editorRef = editorContainer
        // Seed from the editor selection like N++'s incremental search; an
        // empty bar is also fine, the user just types.
        var seed = ""
        if let editor = editorContainer, editor.textView.selectedRange.length > 0 {
            seed = (editor.textView.string as NSString)
                .substring(with: editor.textView.selectedRange)
        }
        bar.show(initialQuery: seed)
        updateLayout()
        view.window?.makeFirstResponder(bar.searchField)
    }

    /// Closes the bar from any caller. The bar's `onClose` hook relayouts.
    func hideIncrementalSearch() {
        incrementalSearchBar?.hide()
    }

    /// Called by the bar after it hides itself (Escape, focus loss, tab
    /// switch). Relayout so the overlay leaves no slot, and return focus to
    /// the editor when this window is active.
    private func incrementalSearchBarDidHide() {
        updateLayout()
        if view.window?.isKeyWindow == true, let textView = editorTextView {
            view.window?.makeFirstResponder(textView)
        }
    }

    // MARK: - Select and Find / Find (Volatile)

    /// The range Select and Find / volatile find act on: the editor selection,
    /// or the word at the caret when the selection is empty. nil means the
    /// command no-ops (there is no query to derive), which is also why the menu
    /// validation can stay enabled.
    private func selectionSearchAnchor() -> NSRange? {
        guard let textView = editorTextView else { return nil }
        return SearchEngine.selectionSearchRange(text: textView.string,
                                                  selection: textView.selectedRange)
    }

    private func selectionSearchTerm(_ anchor: NSRange, in textView: NSTextView) -> String {
        (textView.string as NSString).substring(with: anchor)
    }

    /// Search > Select and Find Next. Seeds the find bar with the current
    /// selection (or word at the caret) and selects the following match.
    @objc func selectAndFindNext(_ sender: Any?) {
        performSelectAndFind(forward: true)
    }

    /// Search > Select and Find Previous. See `selectAndFindNext`.
    @objc func selectAndFindPrevious(_ sender: Any?) {
        performSelectAndFind(forward: false)
    }

    /// Search > Find (Volatile) Next. One-shot search of the selection; leaves
    /// the find bar's query and history alone.
    @objc func findVolatileNext(_ sender: Any?) {
        performVolatileFind(forward: true)
    }

    /// Search > Find (Volatile) Previous. See `findVolatileNext`.
    @objc func findVolatilePrevious(_ sender: Any?) {
        performVolatileFind(forward: false)
    }

    private func performSelectAndFind(forward: Bool) {
        guard let find = findBar, let textView = editorTextView,
              let anchor = selectionSearchAnchor() else { return }
        find.selectAndFind(selectionSearchTerm(anchor, in: textView),
                           direction: forward ? .next : .previous,
                           anchor: anchor)
    }

    private func performVolatileFind(forward: Bool) {
        guard let find = findBar, let textView = editorTextView,
              let anchor = selectionSearchAnchor() else { return }
        find.findVolatile(selectionSearchTerm(anchor, in: textView),
                          direction: forward ? .next : .previous,
                          anchor: anchor)
    }

    // MARK: - Find All (open documents)

    /// Results window for Find All in Current/All Opened Documents. Created on
    /// first use and reused; the file-mode instance stays app-owned in
    /// HexpadAppDelegate, so the two modes never share window state.
    private(set) var searchResultsController: FindInFilesWindowController?

    /// Menu validation: the focused buffer must have text to search.
    func canFindAllInCurrentDocument() -> Bool {
        (tabStore.selectedDocument?.textStorage.length ?? 0) > 0
    }

    /// Menu validation: at least one document open in either split group.
    func canFindAllInAllOpenedDocuments() -> Bool {
        allPanes.contains { $0.tabStore.count > 0 }
    }

    /// Search > Find All in Current Document. The find bar owns the query and
    /// mode flags; the controller owns the results window and the jump back.
    @objc func findAllInCurrentDocument(_ sender: Any?) {
        guard let doc = tabStore.selectedDocument,
              prepareFindAllQuery(),
              let matches = findBar?.findAllInCurrentDocument(doc) else { return }
        showDocumentSearchResults([DocumentSearchGroup(document: doc, matches: matches)])
    }

    /// Search > Find All in All Opened Documents. Every buffer in both groups
    /// is searched, untitled ones included (they are real text buffers). Only
    /// files with hits are listed, matching N++'s per-file grouping.
    @objc func findAllInAllOpenedDocuments(_ sender: Any?) {
        let docs = allPanes.flatMap { $0.tabStore.documents }
        guard !docs.isEmpty, prepareFindAllQuery(),
              let results = findBar?.findAllInAllOpenedDocuments(docs) else { return }
        let groups = results.compactMap { doc, matches in
            matches.isEmpty ? nil : DocumentSearchGroup(document: doc, matches: matches)
        }
        showDocumentSearchResults(groups)
    }

    /// Ensures the bar holds a query before Find All runs. Empty bar: show it,
    /// seed from the editor selection when there is one (the same convenience
    /// as Cmd+F), and let the user press the menu item again if still empty.
    @discardableResult
    private func prepareFindAllQuery() -> Bool {
        guard let find = findBar else { return false }
        if !find.isVisible {
            find.show()
            updateLayout()
        }
        if find.searchField.stringValue.isEmpty,
           let editor = editorContainer,
           editor.textView.selectedRange.length > 0 {
            let selected = (editor.textView.string as NSString)
                .substring(with: editor.textView.selectedRange)
            find.searchField.stringValue = selected
            find.performFind()
        }
        view.window?.makeFirstResponder(find.searchField)
        return !find.searchField.stringValue.isEmpty
    }

    private func showDocumentSearchResults(_ groups: [DocumentSearchGroup]) {
        let controller = searchResultsController ?? makeSearchResultsController()
        let query = findBar?.searchField.stringValue ?? ""
        controller.showDocumentResults(groups: groups,
                                       searchDescription: "\"\(query)\"")
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeSearchResultsController() -> FindInFilesWindowController {
        let controller = FindInFilesWindowController()
        controller.onOpenDocumentMatch = { [weak self] document, range in
            self?.navigateToDocumentMatch(document, range: range)
        }
        searchResultsController = controller
        return controller
    }

    // MARK: - Search result navigation

    /// Search > Next Result (F4). The results window owns the flat row model;
    /// this passthrough lets the menu item work from the main window too.
    /// Hidden or absent results window: no-op.
    @objc func nextSearchResult(_ sender: Any?) {
        guard searchResultsController?.window?.isVisible == true else { return }
        searchResultsController?.nextResult()
    }

    /// Search > Previous Result (Shift+F4). See `nextSearchResult`.
    @objc func previousSearchResult(_ sender: Any?) {
        guard searchResultsController?.window?.isVisible == true else { return }
        searchResultsController?.previousResult()
    }

    // MARK: - Bracket matching

    /// Search > Go to Matching Brace. The focused editor resolves the caret's
    /// language and selects the matching bracket; it no-ops when there is no
    /// adjacent bracket or no match.
    @objc func goToMatchingBrace(_ sender: Any?) {
        editorContainer?.goToMatchingBrace()
    }

    /// Search > Select All In-between. The focused editor selects the text
    /// strictly between the paired brackets at the caret.
    @objc func selectAllInBetweenBraces(_ sender: Any?) {
        editorContainer?.selectAllInBetweenBraces()
    }

    /// Jumps to a document-search hit: activate the owning tab/group first (the
    /// hit may be in the unfocused split group), reveal folded regions, then
    /// select and scroll the exact match range.
    func navigateToDocumentMatch(_ document: DocumentModel, range: NSRange) {
        guard let target = locateDocument(document) else { return }
        focusGroup(target.pane.group)
        selectTab(at: target.index)

        let editor = target.pane.editor
        let length = (editor.textView.string as NSString).length
        guard range.location != NSNotFound, range.location <= length else { return }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, length - range.location))
        editor.reveal(location: clamped.location)
        editor.textView.setSelectedRange(clamped)
        editor.textView.scrollRangeToVisible(clamped)
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(editor.textView)
    }

    /// Identity lookup across both groups; a document belongs to exactly one
    /// tab store, so the first match is authoritative.
    private func locateDocument(_ document: DocumentModel) -> (pane: TabGroupPane, index: Int)? {
        for pane in allPanes {
            if let index = pane.tabStore.documents.firstIndex(where: { $0 === document }) {
                return (pane, index)
            }
        }
        return nil
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

    /// View > Fold Current Level. Targets the innermost fold containing the
    /// caret line; separate from Unfold Current Level (no toggle preference).
    @objc func foldCurrentLevel(_ sender: Any?) {
        performCommand(identifier: "fold-current-level")
    }

    /// View > Unfold Current Level. The inverse of Fold Current Level.
    @objc func unfoldCurrentLevel(_ sender: Any?) {
        performCommand(identifier: "unfold-current-level")
    }

    /// View > Fold Level > Fold Level 1...8. The menu item's tag carries the
    /// 1-based nesting depth, like the tab-colour items.
    @objc func foldLevel(_ sender: NSMenuItem) {
        guard (1...8).contains(sender.tag) else { return }
        performCommand(identifier: "fold-level-\(sender.tag)")
    }

    /// View > Unfold Level > Unfold Level 1...8. The tag carries the depth.
    @objc func unfoldLevel(_ sender: NSMenuItem) {
        guard (1...8).contains(sender.tag) else { return }
        performCommand(identifier: "unfold-level-\(sender.tag)")
    }

    /// Every fold-level command requires an open document with at least one
    /// foldable range, matching Fold All. The level commands validate the same
    /// way whether or not that depth currently exists: depth is cheap to ask
    /// for and the action is a no-op when the document has no such level.
    func canFoldCurrentLevel() -> Bool {
        canFoldAll()
    }

    func canUnfoldCurrentLevel() -> Bool {
        canFoldAll()
    }

    func canFoldLevel(_ depth: Int) -> Bool {
        (1...8).contains(depth) && canFoldAll()
    }

    func canUnfoldLevel(_ depth: Int) -> Bool {
        (1...8).contains(depth) && canFoldAll()
    }

    /// Both fold-all commands require an open document with at least one
    /// foldable range; plain text has nothing to collapse or expand.
    func canFoldAll() -> Bool {
        tabStore.selectedDocument != nil && (editorContainer?.hasFoldableRanges ?? false)
    }

    func canUnfoldAll() -> Bool {
        canFoldAll()
    }

    /// View > Hide Lines. Hides the selected whole lines, or the caret's line
    /// when nothing is selected. Presentation-only: the buffer is untouched,
    /// so find/replace and line operations still see the hidden text.
    @objc func hideLines(_ sender: Any?) {
        _ = editorContainer?.hideSelectedLines()
    }

    /// View > Unhide Lines. Reveals the hidden block at the caret; with none
    /// there, reveals the first hidden block. The margin symbol and selecting
    /// across a block are the two targeted gestures.
    @objc func unhideLines(_ sender: Any?) {
        _ = editorContainer?.unhideSelectedLines()
    }

    /// Hiding needs a document with text. The editor refuses a hide that would
    /// leave no visible line, so validation stays simple and always enabled.
    func canHideLines() -> Bool {
        guard let doc = tabStore.selectedDocument else { return false }
        return !doc.text.isEmpty
    }

    func canUnhideLines() -> Bool {
        editorContainer?.hasHiddenLines ?? false
    }

    // MARK: - Tab colours

    /// View > Tab > Apply Color 1...5. The tag carries the 1-based colour
    /// index. Colours live on the document, so a tab moved to the other pane
    /// keeps its bar and the session restores it.
    @objc func applyTabColor(_ sender: NSMenuItem) {
        guard let doc = tabStore.selectedDocument,
              sender.tag >= 1, sender.tag <= TabColorPalette.colorCount else { return }
        doc.tabColorIndex = sender.tag
        refreshTabBar()
    }

    /// View > Tab > Remove Color. Resets the document's bar to none.
    @objc func removeTabColor(_ sender: Any?) {
        guard let doc = tabStore.selectedDocument, doc.tabColorIndex != nil else { return }
        doc.tabColorIndex = nil
        refreshTabBar()
    }

    /// Applying a colour needs an open document; the colour itself is free.
    func canApplyTabColor() -> Bool {
        tabStore.selectedDocument != nil
    }

    /// Removing is only meaningful once a colour is set.
    func canRemoveTabColor() -> Bool {
        tabStore.selectedDocument?.tabColorIndex != nil
    }

    /// View > Word Wrap. Routes through the registry so the toggle is recorded
    /// while a macro is being captured.
    func toggleWordWrap() {
        performCommand(identifier: "toggle-word-wrap")
    }

    /// View > Document Map. The preference is global, so the store is the
    /// single write path: it posts `.preferencesDidChange` and
    /// `handlePreferencesDidChange` applies the new value to every pane.
    func toggleDocumentMap() {
        let visible = !preferences.minimapVisible
        try? PreferencesStore.update { $0.minimapVisible = visible }
    }

    /// View > Show Symbol > Show Space and Tab. Like Document Map, the store is
    /// the single write path: `.preferencesDidChange` pushes the new value to
    /// every pane through `handlePreferencesDidChange`.
    func toggleShowWhitespace() {
        let visible = !preferences.showWhitespace
        try? PreferencesStore.update { $0.showWhitespace = visible }
    }

    /// View > Show Symbol > Show End of Line.
    func toggleShowEOL() {
        let visible = !preferences.showEOL
        try? PreferencesStore.update { $0.showEOL = visible }
    }

    /// View > Show Symbol > Show All Characters. Notepad++ treats this as one
    /// switch for space/tab and end-of-line glyphs together: it turns both on
    /// unless both are already on.
    func toggleShowAllCharacters() {
        let enable = !(preferences.showWhitespace && preferences.showEOL)
        try? PreferencesStore.update {
            $0.showWhitespace = enable
            $0.showEOL = enable
        }
    }

    /// View > Show Symbol > Show Indent Guide.
    func toggleShowIndentGuide() {
        let visible = !preferences.showIndentGuide
        try? PreferencesStore.update { $0.showIndentGuide = visible }
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
        // The bookmarked-line commands have applicability rules that the
        // pure transform cannot express: Copy changes only the pasteboard,
        // Paste needs a clipboard the command cannot see here, and Inverse is
        // available on any non-empty document.
        switch identifier {
        case "bookmark-cut-lines",
             "bookmark-copy-lines",
             "bookmark-paste-replace-lines",
             "bookmark-remove-lines":
            return !doc.bookmarkState.isEmpty
        case "bookmark-inverse":
            return !doc.text.isEmpty
        default:
            break
        }
        if let applicable = tokenStyleApplicability(identifier: identifier,
                                                    doc: doc,
                                                    editor: editor) {
            return applicable
        }
        let state = DocumentState(text: doc.text,
                                  selection: editor.textView.selectedRange,
                                  bookmarkState: doc.bookmarkState,
                                  tokenStyleState: doc.editorState.tokenStyleState)
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
        case "fold-current-level": return canFoldCurrentLevel()
        case "unfold-current-level": return canUnfoldCurrentLevel()
        case "toggle-word-wrap": return editorContainer != nil
        default:
            if let depth = levelCommandDepth(identifier, prefix: "fold-level-") {
                return canFoldLevel(depth)
            }
            if let depth = levelCommandDepth(identifier, prefix: "unfold-level-") {
                return canUnfoldLevel(depth)
            }
            return false
        }
    }

    /// The 1-based depth encoded in a fold/unfold level command identifier.
    private func levelCommandDepth(_ identifier: String, prefix: String) -> Int? {
        guard identifier.hasPrefix(prefix),
              let depth = Int(identifier.dropFirst(prefix.count)),
              (1...8).contains(depth) else { return nil }
        return depth
    }

    /// Applicability for the Search > token style commands, or `nil` when
    /// `identifier` is not one of them.
    ///
    /// The pure transform cannot express these rules: Copy only changes the
    /// pasteboard, and the style commands are enabled by what the document
    /// currently has, not by whether running them would move the caret.
    private func tokenStyleApplicability(identifier: String,
                                         doc: DocumentModel,
                                         editor: EditorContainer) -> Bool? {
        let selection = editor.textView.selectedRange
        let styles = doc.editorState.tokenStyleState

        if let style = tokenStyleNumber(identifier, prefix: "style-all-occurrences-") {
            return style > 0 && SearchEngine.selectionSearchRange(text: doc.text,
                                                                  selection: selection) != nil
        }
        if let style = tokenStyleNumber(identifier, prefix: "style-one-token-") {
            return style > 0 && SearchEngine.selectionSearchRange(text: doc.text,
                                                                  selection: selection) != nil
        }
        if identifier == "clear-style-all" {
            return !styles.isEmpty
        }
        if let style = tokenStyleNumber(identifier, prefix: "clear-style-") {
            return styles.hasRanges(for: style)
        }
        if let style = tokenStyleNumber(identifier, prefix: "jump-up-") {
            return styles.hasRanges(for: style)
        }
        if let style = tokenStyleNumber(identifier, prefix: "jump-down-") {
            return styles.hasRanges(for: style)
        }
        if let style = tokenStyleNumber(identifier, prefix: "copy-styled-text-") {
            return styles.hasRanges(for: style)
        }
        if identifier == "copy-styled-text-all" {
            return !doc.text.isEmpty
        }
        return nil
    }

    /// The style number encoded in `identifier` after `prefix`, if valid.
    private func tokenStyleNumber(_ identifier: String, prefix: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = identifier.dropFirst(prefix.count)
        guard let style = Int(suffix),
              TokenStyleState.styleNumbers.contains(style) else { return nil }
        return style
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

        guard let outcome = commandResult(identifier: identifier,
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

        let changed = applyCommandResult(outcome.state, to: doc, editor: editor)
        return changed || outcome.wroteClipboard
    }

    /// Installs the live-editor hooks a view-only command needs.
    ///
    /// The closures read the current editor at execution time (not at definition
    /// time), and report whether anything actually changed.
    private func editorCommandContext(for editor: EditorContainer) -> EditorCommandContext {
        EditorCommandContext(
            foldAll: { editor.foldAll() > 0 },
            unfoldAll: { editor.unfoldAll() > 0 },
            toggleWordWrap: { editor.setWordWrapEnabled(!editor.isWordWrapEnabled) },
            foldCurrentLevel: { editor.foldCurrentLevel() },
            unfoldCurrentLevel: { editor.unfoldCurrentLevel() },
            foldLevel: { editor.foldLevel($0) > 0 },
            unfoldLevel: { editor.unfoldLevel($0) > 0 }
        )
    }

    /// Resolves a registry command against the selected document's live state,
    /// passing the macro-style parameter when the command accepts one.
    ///
    /// Clipboard commands read the current pasteboard and write a returned
    /// payload. `wroteClipboard` lets ``performCommand(identifier:parameter:)``
    /// report success even when the buffer itself did not change (Copy).
    private func commandResult(identifier: String,
                               parameter: String?,
                               doc: DocumentModel,
                               editor: EditorContainer) -> (state: DocumentState, wroteClipboard: Bool)? {
        let state = DocumentState(text: doc.text,
                                  selection: editor.textView.selectedRange,
                                  bookmarkState: doc.bookmarkState,
                                  tokenStyleState: doc.editorState.tokenStyleState)
        guard let command = commandRegistry.command(for: identifier) else { return nil }
        if let parameter, let makeAction = command.parameterizedExecute {
            let result = makeAction(parameter)(state.text, state.selection)
            return (DocumentState(text: result.text,
                                  selection: result.selection,
                                  bookmarkState: state.bookmarkState,
                                  tokenStyleState: state.tokenStyleState), false)
        }
        if command.clipboardExecute != nil {
            let pasteboard = NSPasteboard.general
            let output = commandRegistry.execute(identifier,
                                                 on: state,
                                                 clipboard: pasteboard.string(forType: .string))
            guard let output else { return nil }
            if let payload = output.clipboard {
                pasteboard.clearContents()
                pasteboard.setString(payload, forType: .string)
            }
            return (output.state, output.clipboard != nil)
        }
        guard let result = commandRegistry.execute(identifier, on: state) else { return nil }
        return (result, false)
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
        let originalTokenStyles = doc.editorState.tokenStyleState
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

        // Token styles live in the document's editor state. When the command
        // changed them (the style/clear commands), adopt the result. When the
        // command left them untouched but its text edit moved ranges, the
        // storage observer has already remapped the document's state, so the
        // stale pre-edit value must not be written back.
        if result.tokenStyleState != originalTokenStyles {
            doc.editorState.tokenStyleState = result.tokenStyleState
            editor.textView.applyTokenStyles(result.tokenStyleState,
                                             theme: theme(for: editor))
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

    /// First-responder entry point for the Search > token style items.
    ///
    /// They share ``performCommand(identifier:)`` with every other registry
    /// command; the separate selector only groups them for menu validation.
    @objc func performTokenStyleCommand(withIdentifier sender: Any?) {
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
                                   bookmarkState: doc.bookmarkState,
                                   tokenStyleState: doc.editorState.tokenStyleState)
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
            || menuItem.action == #selector(MainWindowController.performBookmarkCommand(withIdentifier:))
            || menuItem.action == #selector(MainWindowController.performTokenStyleCommand(withIdentifier:)) {
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
        if menuItem.action == #selector(MainWindowController.selectNthTabFromMenu(_:)) {
            // View > Tab > Nth Tab: the tag is the 1-based tab number.
            return menuItem.tag >= 1 && menuItem.tag <= tabStore.count
        }
        if menuItem.action == #selector(MainWindowController.selectFirstTab(_:))
            || menuItem.action == #selector(MainWindowController.selectLastTab(_:))
            || menuItem.action == #selector(MainWindowController.moveTabToStart(_:))
            || menuItem.action == #selector(MainWindowController.moveTabToEnd(_:)) {
            // Jumping to an edge or reordering needs a second tab; the move
            // items stay enabled even when the tab is already there, because
            // validation is about applicability, not about a visible effect.
            return tabStore.count > 1
        }
        if menuItem.action == #selector(MainWindowController.sortDocumentsBy(_:)) {
            // Sorting needs at least two tabs to be meaningful.
            return tabStore.count > 1
        }
        if menuItem.action == #selector(MainWindowController.nextSearchResult(_:))
            || menuItem.action == #selector(MainWindowController.previousSearchResult(_:)) {
            return searchResultsController?.window?.isVisible == true
        }
        if menuItem.action == #selector(MainWindowController.goToMatchingBrace(_:))
            || menuItem.action == #selector(MainWindowController.selectAllInBetweenBraces(_:)) {
            // A focused, non-empty buffer is required; the action itself still
            // no-ops safely when the language has no brackets or no match.
            return editorContainer != nil && (tabStore.selectedDocument?.textStorage.length ?? 0) > 0
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
        if menuItem.action == #selector(MainWindowController.foldCurrentLevel(_:)) {
            return canFoldCurrentLevel()
        }
        if menuItem.action == #selector(MainWindowController.unfoldCurrentLevel(_:)) {
            return canUnfoldCurrentLevel()
        }
        if menuItem.action == #selector(MainWindowController.foldLevel(_:)) {
            return canFoldLevel(menuItem.tag)
        }
        if menuItem.action == #selector(MainWindowController.unfoldLevel(_:)) {
            return canUnfoldLevel(menuItem.tag)
        }
        if menuItem.action == #selector(MainWindowController.hideLines(_:)) {
            return canHideLines()
        }
        if menuItem.action == #selector(MainWindowController.unhideLines(_:)) {
            return canUnhideLines()
        }
        if menuItem.action == #selector(MainWindowController.applyTabColor(_:)) {
            // The tag is the 1-based colour index; a checkmark marks the
            // selected document's current colour.
            guard menuItem.tag >= 1, menuItem.tag <= TabColorPalette.colorCount else {
                return false
            }
            menuItem.state = tabStore.selectedDocument?.tabColorIndex == menuItem.tag ? .on : .off
            return canApplyTabColor()
        }
        if menuItem.action == #selector(MainWindowController.removeTabColor(_:)) {
            return canRemoveTabColor()
        }
        if menuItem.action == #selector(MainWindowController.findAllInCurrentDocument(_:)) {
            return canFindAllInCurrentDocument()
        }
        if menuItem.action == #selector(MainWindowController.findAllInAllOpenedDocuments(_:)) {
            return canFindAllInAllOpenedDocuments()
        }
        if menuItem.action == #selector(MainWindowController.toggleIncrementalSearch(_:)) {
            // Needs a focused buffer to search; stays enabled while open so the
            // same item can close it.
            return tabStore.selectedDocument != nil
        }
        if menuItem.action == #selector(MainWindowController.toggleAlwaysOnTop(_:)) {
            menuItem.state = isAlwaysOnTop ? .on : .off
            return windowForModes != nil
        }
        if menuItem.action == #selector(MainWindowController.togglePostIt(_:)) {
            menuItem.state = chromeMode == .postIt ? .on : .off
            return windowForModes != nil
        }
        if menuItem.action == #selector(MainWindowController.toggleDistractionFreeMode(_:)) {
            menuItem.state = chromeMode == .distractionFree ? .on : .off
            return windowForModes != nil
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
        if menuItem.action == #selector(MainWindowController.reloadActiveDocument(_:)) {
            return tabStore.selectedDocument?.filePath != nil
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
        if let pane = pane(containing: textView), let docUndo = pane.boundDocument?.undoManager {
            return docUndo
        }
        // Never fall back to textView.undoManager: NSTextView re-enters this
        // delegate method, so the fallback recurses until the stack overflows
        // (launch crash when menu validation asks before any pane binds the
        // view). The window's undo manager is the same object NSTextView would
        // resolve to, obtained without re-entrancy.
        return view.window?.undoManager
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
