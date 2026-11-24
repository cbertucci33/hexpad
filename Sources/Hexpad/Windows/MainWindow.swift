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
    }
}

// MARK: - V19t: N++ default toolbar (20 buttons)

/// One toolbar button/separator, pinned so the N++ order, label, SF Symbol and
/// action target convention live in a single table. `symbolName == nil` marks
/// a separator; `targetsDelegate` mirrors the menu section that owns the action:
/// true for delegate-targeted menu items (File/Search/View actions), false for
/// the nil-targeted first-responder items (clipboard, undo, Print, Show Symbol,
/// scroll sync).
private struct ToolbarItemSpec {
    let identifier: NSToolbarItem.Identifier
    let label: String
    let toolTip: String
    let symbolName: String?
    let action: Selector?
    let targetsDelegate: Bool
}

extension MainWindow {
    
    /// N++ default order. Separators split the five groups:
    /// file / clipboard / undo / search / view.
    static let defaultToolbarIdentifiers: [NSToolbarItem.Identifier] = [
        .toolbarNew, .toolbarOpen, .toolbarSave, .toolbarSaveAll,
        .toolbarClose, .toolbarCloseAll, .toolbarPrint,
        .toolbarSeparatorAfterPrint,
        .toolbarCut, .toolbarCopy, .toolbarPaste,
        .toolbarSeparatorAfterPaste,
        .toolbarUndo, .toolbarRedo,
        .toolbarSeparatorAfterRedo,
        .toolbarFind, .toolbarReplace,
        .toolbarSeparatorAfterReplace,
        .toolbarZoomIn, .toolbarZoomOut,
        .toolbarSyncVertical, .toolbarSyncHorizontal,
        .toolbarWordWrap, .toolbarShowAllCharacters
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
            
            // Search group. Hexpad's FindBar holds the replace field, so Replace
            // reuses the Find toggle (the one search-bar entry point).
            ToolbarItemSpec(identifier: .toolbarFind, label: "Find",
                            toolTip: "Search > Find: Toggles the find bar.",
                            symbolName: "magnifyingglass",
                            action: #selector(HexpadAppDelegate.toggleFindBar), targetsDelegate: true),
            ToolbarItemSpec(identifier: .toolbarReplace, label: "Replace",
                            toolTip: "Search > Find: Toggles the find bar (includes replace).",
                            symbolName: "arrow.left.arrow.right",
                            action: #selector(HexpadAppDelegate.toggleFindBar), targetsDelegate: true),
            
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
                            action: #selector(HexpadAppDelegate.toggleShowAllCharacters), targetsDelegate: false)
        ]
        let separators = [
            ToolbarItemSpec(identifier: .toolbarSeparatorAfterPrint, label: "", toolTip: "",
                            symbolName: nil, action: nil, targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarSeparatorAfterPaste, label: "", toolTip: "",
                            symbolName: nil, action: nil, targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarSeparatorAfterRedo, label: "", toolTip: "",
                            symbolName: nil, action: nil, targetsDelegate: false),
            ToolbarItemSpec(identifier: .toolbarSeparatorAfterReplace, label: "", toolTip: "",
                            symbolName: nil, action: nil, targetsDelegate: false)
        ]
        return Dictionary(uniqueKeysWithValues: (specs + separators).map { ($0.identifier, $0) })
    }()
    
    /// Separator items draw a 1pt rule and are not clickable (no action,
    /// nil target). The navigational flag is kept for the delegate contract
    /// (ToolbarTests pins it); `toolbarWillAddItem` clears it when the item is
    /// actually inserted, because macOS 26 renders navigational custom views
    /// as empty leading capsules in a unified compact titlebar.
    private func makeSeparatorItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isNavigational = true
        let rule = NSBox(frame: NSRect(x: 0, y: 4, width: 1, height: 24))
        rule.boxType = .separator
        item.view = rule
        return item
    }
}

extension MainWindow: NSToolbarDelegate {
    /// macOS 26 puts navigational custom-view items in the titlebar's leading
    /// navigation area and wraps them in empty glass capsules: the three ghost
    /// panes CB saw between the traffic lights and the title are these
    /// separators. The separator factory still returns `isNavigational = true`
    /// (ToolbarTests pins that flag), so clear it as each item is inserted:
    /// separators must stay inline between their button groups, not lead.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              item.view is NSBox else { return }
        item.isNavigational = false
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        if itemIdentifier == .flexibleSpace {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.isNavigational = true
            return item
        }
        guard let spec = Self.toolbarSpecs[itemIdentifier] else { return nil }
        
        guard let symbolName = spec.symbolName else {
            return makeSeparatorItem(itemIdentifier)
        }
        
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.toolTip = spec.toolTip
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: spec.label)
        item.action = spec.action
        // Delegate-targeted actions resolve to the app delegate, exactly as
        // their menu-section counterparts do. First-responder actions keep a
        // nil target and travel the same responder chain as the menu items.
        item.target = spec.targetsDelegate ? (NSApp.delegate as? HexpadAppDelegate) : nil
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
    static let flexibleSpace = NSToolbarItem.Identifier("flexibleSpace")
    
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
    
    static let toolbarSeparatorAfterPrint = NSToolbarItem.Identifier("toolbar.separator.afterPrint")
    static let toolbarSeparatorAfterPaste = NSToolbarItem.Identifier("toolbar.separator.afterPaste")
    static let toolbarSeparatorAfterRedo = NSToolbarItem.Identifier("toolbar.separator.afterRedo")
    static let toolbarSeparatorAfterReplace = NSToolbarItem.Identifier("toolbar.separator.afterReplace")
}
