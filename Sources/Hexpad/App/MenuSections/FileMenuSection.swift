import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeFileMenu() -> NSMenu {
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        newWindowItem.target = self
        let newItem = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        newItem.target = self
        let openItem = NSMenuItem(title: "Open...", action: #selector(openFile), keyEquivalent: "o")
        openItem.target = self
        // Notepad++'s File > Open Containing Folder. Both leaves are
        // nil-targeted so the delegate's NSMenuItemValidation disables them for
        // untitled buffers, like View > View Current File In.
        let openContainingFolderItem = NSMenuItem(title: "Open Containing Folder",
                                                  action: nil,
                                                  keyEquivalent: "")
        let openContainingFolderMenu = NSMenu(title: "Open Containing Folder")
        let revealInFinderItem = NSMenuItem(title: "Finder",
                                            action: #selector(HexpadAppDelegate.openContainingFolderInFinder(_:)),
                                            keyEquivalent: "")
        revealInFinderItem.target = nil
        let openInTerminalItem = NSMenuItem(title: "Terminal",
                                            action: #selector(HexpadAppDelegate.openContainingFolderInTerminal(_:)),
                                            keyEquivalent: "")
        openInTerminalItem.target = nil
        openContainingFolderMenu.addItem(revealInFinderItem)
        openContainingFolderMenu.addItem(openInTerminalItem)
        openContainingFolderItem.submenu = openContainingFolderMenu
        // Notepad++'s Open in Default Viewer sits at the end of the open group;
        // nil-targeted for the same file-backed-document validation.
        let openInDefaultViewerItem = NSMenuItem(title: "Open in Default Viewer",
                                                 action: #selector(HexpadAppDelegate.openInDefaultViewer(_:)),
                                                 keyEquivalent: "")
        openInDefaultViewerItem.target = nil
        let openFolderItem = NSMenuItem(title: "Open Folder as Workspace…",
                                        action: #selector(openFolderAsWorkspace),
                                        keyEquivalent: "")
        openFolderItem.target = self
        let saveItem = NSMenuItem(title: "Save", action: #selector(saveFile), keyEquivalent: "s")
        saveItem.target = self
        let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(saveAsFile), keyEquivalent: "S")
        saveAsItem.target = self
        let saveAllItem = NSMenuItem(title: "Save All", action: #selector(saveAllFiles), keyEquivalent: "")
        saveAllItem.target = self
        // Nil-targeted so MainWindowController validates against the focused
        // group's selected document.
        let reloadItem = NSMenuItem(title: "Reload from Disk",
                                    action: #selector(MainWindowController.reloadActiveDocument(_:)),
                                    keyEquivalent: "")
        reloadItem.target = nil
        // Nil-targeted so MainWindowController validates against the focused
        // group's selected document.
        let printItem = NSMenuItem(title: "Print…",
                                   action: #selector(MainWindowController.printDocument(_:)),
                                   keyEquivalent: "p")
        printItem.target = nil
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        closeTabItem.target = self
        let closeAllItem = NSMenuItem(title: "Close All Tabs", action: #selector(closeAllTabs), keyEquivalent: "W")
        closeAllItem.target = self

        // Bulk close variants; each targets the focused group's tab order and
        // reuses the single-close dirty prompt per document.
        let closeMultipleItem = NSMenuItem(title: "Close Multiple Documents", action: nil, keyEquivalent: "")
        let closeMultipleMenu = NSMenu(title: "Close Multiple Documents")
        let closeOthers = NSMenuItem(title: "Close All but Active Document",
                                     action: #selector(closeAllButActiveDocument),
                                     keyEquivalent: "")
        closeOthers.target = self
        let closeUnpinned = NSMenuItem(title: "Close All but Pinned Documents",
                                       action: #selector(closeAllButPinnedDocuments),
                                       keyEquivalent: "")
        closeUnpinned.target = self
        let closeLeft = NSMenuItem(title: "Close All to the Left",
                                   action: #selector(closeAllDocumentsToLeft),
                                   keyEquivalent: "")
        closeLeft.target = self
        let closeRight = NSMenuItem(title: "Close All to the Right",
                                    action: #selector(closeAllDocumentsToRight),
                                    keyEquivalent: "")
        closeRight.target = self
        let closeUnchanged = NSMenuItem(title: "Close All Unchanged",
                                        action: #selector(closeAllUnchangedDocuments),
                                        keyEquivalent: "")
        closeUnchanged.target = self
        closeMultipleMenu.addItem(closeOthers)
        closeMultipleMenu.addItem(closeUnpinned)
        closeMultipleMenu.addItem(closeLeft)
        closeMultipleMenu.addItem(closeRight)
        closeMultipleMenu.addItem(closeUnchanged)
        closeMultipleItem.submenu = closeMultipleMenu
        
        // Open Recent submenu
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        self.openRecentMenu = openRecentMenu
        for item in makeRecentFileCommandItems() {
            openRecentMenu.addItem(item)
        }
        
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(newItem)
        fileMenu.addItem(openItem)
        fileMenu.addItem(openContainingFolderItem)
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(openFolderItem)
        fileMenu.addItem(openInDefaultViewerItem)
        fileMenu.addItem(saveItem)
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(saveAllItem)
        fileMenu.addItem(reloadItem)
        fileMenu.addItem(printItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeTabItem)
        fileMenu.addItem(closeAllItem)
        fileMenu.addItem(closeMultipleItem)
        return fileMenu
    }

    /// Tail of the File > Open Recent submenu: N++'s three commands after the
    /// file list. Shared by the initial menu build and the per-open rebuild in
    /// `menuNeedsUpdate`, which would otherwise discard statically added items.
    func makeRecentFileCommandItems() -> [NSMenuItem] {
        let restoreItem = NSMenuItem(title: "Restore Recent Closed File",
                                     action: #selector(restoreRecentClosedFile),
                                     keyEquivalent: "")
        restoreItem.target = self
        let openAllItem = NSMenuItem(title: "Open All Recent Files",
                                     action: #selector(openAllRecentFiles),
                                     keyEquivalent: "")
        openAllItem.target = self
        let emptyItem = NSMenuItem(title: "Empty Recent Files List",
                                   action: #selector(emptyRecentFilesList),
                                   keyEquivalent: "")
        emptyItem.target = self
        return [.separator(), restoreItem, openAllItem, emptyItem]
    }
}
