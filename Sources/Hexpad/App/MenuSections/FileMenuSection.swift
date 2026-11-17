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
        
        // Open Recent submenu
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        self.openRecentMenu = openRecentMenu
        
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(newItem)
        fileMenu.addItem(openItem)
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(openFolderItem)
        fileMenu.addItem(saveItem)
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(saveAllItem)
        fileMenu.addItem(reloadItem)
        fileMenu.addItem(printItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeTabItem)
        fileMenu.addItem(closeAllItem)
        return fileMenu
    }
}
