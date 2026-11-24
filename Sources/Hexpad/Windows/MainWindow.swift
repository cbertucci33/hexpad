import AppKit
import HexpadKit

class MainWindow: NSWindow {
    
    init() {
        let rect = NSRect(x: 100, y: 100, width: 1000, height: 700)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        
        title = "Hexpad"
        isReleasedWhenClosed = false
        // Custom session restore owns persistence (HexpadApp session.json).
        // macOS's own window state restoration must stay OFF: with it on,
        // Saved Application State resurrects stale NATIVE window-tab groups
        // from older builds (ghost capsule tiles in the titlebar ahead of the
        // title). CB-reported header spacer bug, 2026-11-23.
        isRestorable = false
        minSize = NSSize(width: 800, height: 500)
        // Hexpad tabs documents in its own TabBarView. Native window tabs would
        // merge Cmd+N windows into a macOS tab group and draw their own titlebar
        // chrome, so this window never participates in automatic tabbing.
        tabbingMode = .disallowed
        
        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.delegate = self
        // The default (automatic/unified) style measures 66pt on macOS 26,
        // which reads as a giant empty header. The compact style is the modern
        // small-toolbar metric and measures well under 52pt.
        toolbarStyle = .unifiedCompact
        self.toolbar = toolbar
        // CB: ZERO lines around the toolbar icons. macOS 26 still paints the
        // 1pt titlebar separator even when titlebarSeparatorStyle is .none
        // (verified on 26.7.1; NSToolbar.showsBaselineSeparator is a deprecated
        // no-op). A transparent titlebar is the only switch that actually
        // removes that hairline, and it also clears the band behind the icons.
        titlebarSeparatorStyle = .none
        titlebarAppearsTransparent = true
    }
}

// MARK: - V19t: N++ default toolbar (20 buttons)

/// One toolbar button, pinned so the N++ order, label, SF Symbol and action
/// target convention live in a single table. `targetsDelegate` mirrors the menu
/// section that owns the action: true for delegate-targeted menu items
/// (File/Search/View actions), false for the nil-targeted first-responder items
/// (clipboard, undo, Print, Show Symbol, scroll sync).
private struct ToolbarItemSpec {
    let identifier: NSToolbarItem.Identifier
    let label: String
    let toolTip: String
    let symbolName: String
    let action: Selector?
    let targetsDelegate: Bool
}

extension MainWindow {
    
    /// N++ default order. Standard `.space` items split the five groups:
    /// file / clipboard / undo / search / view. They are created by AppKit and
    /// draw nothing — unlike a custom-view spacer, which macOS 26 wraps in a
    /// visible glass capsule.
    static let defaultToolbarIdentifiers: [NSToolbarItem.Identifier] = [
        .toolbarNew, .toolbarOpen, .toolbarSave, .toolbarSaveAll,
        .toolbarClose, .toolbarCloseAll, .toolbarPrint,
        .space,
        .toolbarCut, .toolbarCopy, .toolbarPaste,
        .space,
        .toolbarUndo, .toolbarRedo,
        .space,
        .toolbarFind, .toolbarReplace,
        .space,
        .toolbarZoomIn, .toolbarZoomOut,
        .toolbarSyncVertical, .toolbarSyncHorizontal,
        .toolbarWordWrap, .toolbarShowAllCharacters,
        // N++ extended View/tools group (user-interface.txt:222-254).
        .toolbarShowIndentGuide, .toolbarDocumentMap,
        .toolbarFunctionList, .toolbarFolderAsWorkspace,
        .toolbarMonitoring,
        .toolbarStartRecording, .toolbarStopRecording,
        .toolbarPlayback, .toolbarRunMacroMultipleTimes, .toolbarSaveMacro
    ]
    
    private static let toolbarSpecs: [NSToolbarItem.Identifier: ToolbarItemSpec] = {
        let specs = [
            // File group. New is File > New Tab (a new document in N++ terms).
            ToolbarItemSpec(identifier: .toolbarNew, label: "New",
                            toolTip: "File > New Tab: Creates a new document.",
                            symbolName: "doc.badge.plus",
                            action: #selector(HexpadAppDelegate.newTab), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarOpen, label: "Open",
                            toolTip: "File > Open: Opens an existing file.",
                            symbolName: "folder",
                            action: #selector(HexpadAppDelegate.openFile), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarSave, label: "Save",
                            toolTip: "File > Save: Saves the active file.",
                            symbolName: "square.and.arrow.down",
                            action: #selector(HexpadAppDelegate.saveFile), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarSaveAll, label: "Save All",
                            toolTip: "File > Save All: Saves all open files.",
                            symbolName: "square.and.arrow.down.on.square",
                            action: #selector(HexpadAppDelegate.saveAllFiles), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarClose, label: "Close",
                            toolTip: "File > Close Tab: Closes the active tab.",
                            symbolName: "xmark.square",
                            action: #selector(HexpadAppDelegate.closeTab), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarCloseAll, label: "Close All",
                            toolTip: "File > Close All Tabs: Closes every open tab.",
                            symbolName: "xmark.square.fill",
                            action: #selector(HexpadAppDelegate.closeAllTabs), targetsDelegate: true),
            // Print opens the dialog (File > Print), not the one-click Print Now.
            ToolbarItemSpec(identifier: .toolbarPrint, label: "Print",
                            toolTip: "File > Print: Opens the print dialog.",
                            symbolName: "printer",
                            action: #selector(MainWindowController.printDocument(_:)), targetsDelegate: false),
            
            // Clipboard group — NSText selectors, nil-targeted like the Edit menu.
            ToolbarItemSpec(identifier: .toolbarCut, label: "Cut",
                            toolTip: "Edit > Cut: Cuts the selection to the clipboard.",
                            symbolName: "scissors",
                            action: #selector(NSText.cut(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarCopy, label: "Copy",
                            toolTip: "Edit > Copy: Copies the selection to the clipboard.",
                            symbolName: "doc.on.doc",
                            action: #selector(NSText.copy(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarPaste, label: "Paste",
                            toolTip: "Edit > Paste: Pastes from the clipboard.",
                            symbolName: "clipboard",
                            action: #selector(NSText.paste(_:)), targetsDelegate: false),
            
            // Undo group — same raw selectors the Edit menu uses.
            ToolbarItemSpec(identifier: .toolbarUndo, label: "Undo",
                            toolTip: "Edit > Undo: Undoes the last action.",
                            symbolName: "arrow.uturn.backward",
                            action: Selector(("undo:")), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarRedo, label: "Redo",
                            toolTip: "Edit > Redo: Redoes the last undone action.",
                            symbolName: "arrow.uturn.forward",
                            action: Selector(("redo:")), targetsDelegate: false),
            
            // Search group. Find and Replace share the one bar but open
            // distinct modes: Find is query-only, Replace reveals the
            // replacement field and focuses it.
            ToolbarItemSpec(identifier: .toolbarFind, label: "Find",
                            toolTip: "Search > Find: Opens the find bar in find-only mode.",
                            symbolName: "magnifyingglass",
                            action: #selector(HexpadAppDelegate.toggleFindBar), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarReplace, label: "Replace",
                            toolTip: "Search > Replace: Opens the find bar with the replace field.",
                            symbolName: "arrow.left.arrow.right",
                            action: #selector(HexpadAppDelegate.toggleReplaceBar), targetsDelegate: true),
            
            // View group.
            ToolbarItemSpec(identifier: .toolbarZoomIn, label: "Zoom In",
                            toolTip: "View > Zoom In: Increases the editor font size.",
                            symbolName: "plus.magnifyingglass",
                            action: #selector(HexpadAppDelegate.zoomIn), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarZoomOut, label: "Zoom Out",
                            toolTip: "View > Zoom Out: Decreases the editor font size.",
                            symbolName: "minus.magnifyingglass",
                            action: #selector(HexpadAppDelegate.zoomOut), targetsDelegate: true),
            // Hexpad has one scroll-sync toggle (vertical only). The horizontal
            // button keeps N++'s 20-button layout and reuses that single setting;
            // no separate horizontal action has been invented.
            ToolbarItemSpec(identifier: .toolbarSyncVertical, label: "Synchronize Vertical Scrolling",
                            toolTip: "View > Synchronize Scrolling: Syncs the two views' vertical scroll.",
                            symbolName: "arrow.up.and.down",
                            action: #selector(MainWindowController.toggleSynchronizeScrolling(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarSyncHorizontal, label: "Synchronize Horizontal Scrolling",
                            toolTip: "View > Synchronize Scrolling: Scroll synchronization (horizontal not yet shipped).",
                            symbolName: "arrow.left.and.right",
                            action: #selector(MainWindowController.toggleSynchronizeScrolling(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarWordWrap, label: "Word Wrap",
                            toolTip: "View > Word Wrap: Toggles line wrapping.",
                            symbolName: "arrow.turn.down.left",
                            action: #selector(HexpadAppDelegate.toggleWordWrap), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarShowAllCharacters, label: "Show All Characters",
                            toolTip: "View > Show Symbol > Show All Characters: Shows whitespace and EOL marks.",
                            symbolName: "character",
                            action: #selector(HexpadAppDelegate.toggleShowAllCharacters), targetsDelegate: false),

            // N++ extended View group. Each button reuses the exact selector
            // and target convention of its menu item: delegate-targeted for
            // View menu items that target the app delegate, nil-targeted for
            // the first-responder items validated by MainWindowController.
            ToolbarItemSpec(identifier: .toolbarShowIndentGuide, label: "Show Indent Guide",
                            toolTip: "View > Show Symbol > Show Indent Guide: Toggles indent guide lines.",
                            symbolName: "increase.indent",
                            action: #selector(HexpadAppDelegate.toggleShowIndentGuide), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarDocumentMap, label: "Document Map",
                            toolTip: "View > Document Map: Toggles the document minimap.",
                            symbolName: "map",
                            action: #selector(HexpadAppDelegate.toggleDocumentMap), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarFunctionList, label: "Function List",
                            toolTip: "View > Function List: Shows the document outline.",
                            symbolName: "list.bullet.rectangle",
                            action: #selector(MainWindowController.toggleFunctionList(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarFolderAsWorkspace, label: "Folder as Workspace",
                            toolTip: "View > Folder as Workspace: Shows the workspace panel.",
                            symbolName: "folder.badge.plus",
                            action: #selector(MainWindowController.toggleWorkspacePanel(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarMonitoring, label: "Monitoring (tail -f)",
                            toolTip: "Tools > Monitor File: Follows the file on disk (tail -f).",
                            symbolName: "dot.radiowaves.left.and.right",
                            action: #selector(MainWindowController.toggleFileMonitoring(_:)), targetsDelegate: false),

            // N++ macro group (Macro menu). Recording state is controller-owned,
            // so every item is nil-targeted and validated by the responder chain.
            ToolbarItemSpec(identifier: .toolbarStartRecording, label: "Start Recording",
                            toolTip: "Macro > Record Macro: Starts recording a macro.",
                            symbolName: "record.circle",
                            action: #selector(MainWindowController.toggleMacroRecording(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarStopRecording, label: "Stop Recording",
                            toolTip: "Macro > Stop Recording: Stops the current recording.",
                            symbolName: "stop.circle",
                            action: #selector(MainWindowController.stopRecordingMacro(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarPlayback, label: "Playback",
                            toolTip: "Macro > Play Last Macro: Plays the most recent macro.",
                            symbolName: "play.circle",
                            action: #selector(MainWindowController.playLastMacro(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarRunMacroMultipleTimes, label: "Run a Macro Multiple Times…",
                            toolTip: "Macro > Run a Macro Multiple Times…: Repeats the last macro.",
                            symbolName: "repeat",
                            action: #selector(MainWindowController.showRunMacroMultipleTimesDialog(_:)), targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarSaveMacro, label: "Save Current Recorded Macro…",
                            toolTip: "Macro > Save Recording As…: Saves the current recording.",
                            symbolName: "tray.and.arrow.down",
                            action: #selector(MainWindowController.saveRecordingAs(_:)), targetsDelegate: false)
        ]
        return Dictionary(uniqueKeysWithValues: specs.map { ($0.identifier, $0) })
    }()
}

extension MainWindow: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        // Standard spacing identifiers are built by AppKit itself; asking the
        // delegate for one would produce an empty custom item, i.e. chrome.
        if itemIdentifier == .space || itemIdentifier == .flexibleSpace {
            return nil
        }
        guard let spec = Self.toolbarSpecs[itemIdentifier] else { return nil }
        
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.toolTip = spec.toolTip
        item.image = NSImage(systemSymbolName: spec.symbolName, accessibilityDescription: spec.label)
        item.action = spec.action
        // Delegate-targeted actions resolve to the app delegate, exactly as
        // their menu-section counterparts do. First-responder actions keep a
        // nil target and travel the same responder chain as the menu items.
        item.target = spec.targetsDelegate ? (NSApp.delegate as? HexpadAppDelegate) : nil
        // CB: ZERO lines around icons — transparent spacing only, no button
        // border/box in light or dark appearance.
        item.isBordered = false
        return item
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.defaultToolbarIdentifiers + [.flexibleSpace]
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.defaultToolbarIdentifiers
    }
}

extension NSToolbarItem.Identifier {
    // `.space` and `.flexibleSpace` are the AppKit standard identifiers; the
    // toolbar builds them itself and never asks this delegate for a view.
    static let toolbarNew = NSToolbarItem.Identifier("toolbar.new")
    static let toolbarOpen = NSToolbarItem.Identifier("toolbar.open")
    static let toolbarSave = NSToolbarItem.Identifier("toolbar.save")
    static let toolbarSaveAll = NSToolbarItem.Identifier("toolbar.saveAll")
    static let toolbarClose = NSToolbarItem.Identifier("toolbar.close")
    static let toolbarCloseAll = NSToolbarItem.Identifier("toolbar.closeAll")
    static let toolbarPrint = NSToolbarItem.Identifier("toolbar.print")
    static let toolbarCut = NSToolbarItem.Identifier("toolbar.cut")
    static let toolbarCopy = NSToolbarItem.Identifier("toolbar.copy")
    static let toolbarPaste = NSToolbarItem.Identifier("toolbar.paste")
    static let toolbarUndo = NSToolbarItem.Identifier("toolbar.undo")
    static let toolbarRedo = NSToolbarItem.Identifier("toolbar.redo")
    static let toolbarFind = NSToolbarItem.Identifier("toolbar.find")
    static let toolbarReplace = NSToolbarItem.Identifier("toolbar.replace")
    static let toolbarZoomIn = NSToolbarItem.Identifier("toolbar.zoomIn")
    static let toolbarZoomOut = NSToolbarItem.Identifier("toolbar.zoomOut")
    static let toolbarSyncVertical = NSToolbarItem.Identifier("toolbar.syncVertical")
    static let toolbarSyncHorizontal = NSToolbarItem.Identifier("toolbar.syncHorizontal")
    static let toolbarWordWrap = NSToolbarItem.Identifier("toolbar.wordWrap")
    static let toolbarShowAllCharacters = NSToolbarItem.Identifier("toolbar.showAllCharacters")
    static let toolbarShowIndentGuide = NSToolbarItem.Identifier("toolbar.showIndentGuide")
    static let toolbarDocumentMap = NSToolbarItem.Identifier("toolbar.documentMap")
    static let toolbarFunctionList = NSToolbarItem.Identifier("toolbar.functionList")
    static let toolbarFolderAsWorkspace = NSToolbarItem.Identifier("toolbar.folderAsWorkspace")
    static let toolbarMonitoring = NSToolbarItem.Identifier("toolbar.monitoring")
    static let toolbarStartRecording = NSToolbarItem.Identifier("toolbar.startRecording")
    static let toolbarStopRecording = NSToolbarItem.Identifier("toolbar.stopRecording")
    static let toolbarPlayback = NSToolbarItem.Identifier("toolbar.playback")
    static let toolbarRunMacroMultipleTimes = NSToolbarItem.Identifier("toolbar.runMacroMultipleTimes")
    static let toolbarSaveMacro = NSToolbarItem.Identifier("toolbar.saveMacro")
}
