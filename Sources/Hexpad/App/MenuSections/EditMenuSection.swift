import AppKit
import HexpadKit

/// Notepad++'s Edit > Copy to Clipboard variants. The raw value doubles as the
/// menu item tag, so one delegate action serves all five entries.
enum CopyPathVariant: Int, CaseIterable {
    case currentFullPath
    case currentFilename
    case currentDirectory
    case allFilenames
    case allPaths

    /// Current variants read the focused tab and are no-ops on an untitled
    /// buffer; All variants span every file-backed tab in the window.
    var isCurrent: Bool {
        switch self {
        case .currentFullPath, .currentFilename, .currentDirectory: return true
        case .allFilenames, .allPaths: return false
        }
    }
}

/// Builds the clipboard text for the Copy to Clipboard entries. Untitled
/// documents have no path, so they contribute nothing to the All variants and
/// make the Current variants return nil (the action then leaves the pasteboard
/// untouched).
enum CopyPathCollector {
    static func text(for variant: CopyPathVariant,
                     selected: DocumentModel?,
                     documents: [DocumentModel]) -> String? {
        switch variant {
        case .currentFullPath, .currentFilename, .currentDirectory:
            guard let url = selected?.filePath else { return nil }
            switch variant {
            case .currentFullPath: return url.path
            case .currentFilename: return url.lastPathComponent
            default: return url.deletingLastPathComponent().path
            }
        case .allFilenames, .allPaths:
            let urls = documents.compactMap(\.filePath)
            guard !urls.isEmpty else { return nil }
            return urls
                .map { variant == .allFilenames ? $0.lastPathComponent : $0.path }
                .joined(separator: "\n")
        }
    }
}

extension HexpadAppDelegate {
    func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let findItem = NSMenuItem(title: "Find...", action: #selector(toggleFindBar), keyEquivalent: "f")
        findItem.target = self

        // Notepad++ nests the path-copying commands right under Copy. All five
        // share one action; the tag selects the variant (and drives validation).
        let copyPathItem = NSMenuItem(title: "Copy to Clipboard", action: nil, keyEquivalent: "")
        let copyPathMenu = NSMenu(title: "Copy to Clipboard")
        let pathVariants: [(CopyPathVariant, String)] = [
            (.currentFullPath, "Copy Current Full File Path"),
            (.currentFilename, "Copy Current Filename"),
            (.currentDirectory, "Copy Current Dir. Path"),
            (.allFilenames, "Copy All Filenames"),
            (.allPaths, "Copy All File Paths")
        ]
        for (variant, title) in pathVariants {
            let item = NSMenuItem(title: title,
                                  action: #selector(copyPathToClipboard(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = variant.rawValue
            copyPathMenu.addItem(item)
        }
        copyPathItem.submenu = copyPathMenu
        
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(copyPathItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        editMenu.addItem(findItem)
        return editMenu
    }
}
