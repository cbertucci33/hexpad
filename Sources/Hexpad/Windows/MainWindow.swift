import AppKit
import HexpadKit

class MainWindow: NSWindow {
    
    init() {
        let rect = NSRect(x: 100, y: 100, width: 1000, height: 700)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        
        title = "Hexpad"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 800, height: 500)
        
        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.delegate = self
        toolbar.showsBaselineSeparator = true
        self.toolbar = toolbar
    }
}

extension MainWindow: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: NSToolbar) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .flexibleSpace:
            item.isNavigational = true
        default:
            break
        }
        return item
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace]
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }
}

extension NSToolbarItem.Identifier {
    static let flexibleSpace = NSToolbarItem.Identifier("flexibleSpace")
}
