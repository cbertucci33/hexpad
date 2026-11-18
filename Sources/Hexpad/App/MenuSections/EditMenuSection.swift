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

        // Notepad++ nests the eight text-case conversions under Edit >
        // Convert Case to. They run through the shared registry command path,
        // so validation (no-op cases disabled) and macro recording match the
        // other editor commands.
        let convertCaseItem = NSMenuItem(title: "Convert Case to", action: nil, keyEquivalent: "")
        let convertCaseMenu = NSMenu(title: "Convert Case to")
        for command in CommandRegistry.default.caseCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(MainWindowController.performCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.target = nil
            item.representedObject = command.identifier
            convertCaseMenu.addItem(item)
        }
        convertCaseItem.submenu = convertCaseMenu

        // Notepad++ nests Increase/Decrease Line Indent under Edit > Indent.
        // Cmd+] / Cmd+[ are the standard Mac editor chords; the Window menu's
        // Cmd+Shift+] / Cmd+Shift+[ previous/next-tab items are the shifted
        // variants, so there is no collision. The target reads the focused
        // controller's Preferences at action time and passes the tabs-vs-spaces
        // policy through the command's macro-style parameter, keeping the
        // single registry/undo path.
        let indentItem = NSMenuItem(title: "Indent", action: nil, keyEquivalent: "")
        let indentMenu = NSMenu(title: "Indent")
        for command in CommandRegistry.default.indentCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(performIndentCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command.identifier
            switch command.identifier {
            case "indent-increase":
                item.keyEquivalent = "]"
                item.keyEquivalentModifierMask = [.command]
            case "indent-decrease":
                item.keyEquivalent = "["
                item.keyEquivalentModifierMask = [.command]
            default:
                break
            }
            indentMenu.addItem(item)
        }
        indentItem.submenu = indentMenu

        // Notepad++ nests its three Date Time inserts under Edit > Insert >
        // Date Time. The short/long commands format the current clock when they
        // run; the customized one receives the live Settings pattern through
        // the same parameter path the Indent commands use, so a macro replay
        // reproduces the format the user had at record time.
        let insertItem = NSMenuItem(title: "Insert", action: nil, keyEquivalent: "")
        let insertMenu = NSMenu(title: "Insert")
        let dateTimeItem = NSMenuItem(title: "Date Time", action: nil, keyEquivalent: "")
        let dateTimeMenu = NSMenu(title: "Date Time")
        for command in CommandRegistry.default.dateCommands {
            let item = NSMenuItem(title: command.title,
                                  action: #selector(performDateInsertCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command.identifier
            dateTimeMenu.addItem(item)
        }
        dateTimeItem.submenu = dateTimeMenu
        insertMenu.addItem(dateTimeItem)
        insertItem.submenu = insertMenu

        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(copyPathItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        editMenu.addItem(convertCaseItem)
        editMenu.addItem(indentItem)
        editMenu.addItem(insertItem)
        editMenu.addItem(.separator())
        editMenu.addItem(findItem)

        // Notepad++ puts Read-Only near the end of Edit. Two delegate-targeted
        // entries: one toggles the focused document, the other applies the
        // focused document's NEW state to every open tab in both split groups.
        // Both are stored on the delegate so checkmarks can be refreshed from
        // the controller's tab-switch path as well as from menu validation.
        editMenu.addItem(.separator())
        let readOnlyItem = NSMenuItem(title: "Read-Only",
                                      action: #selector(HexpadAppDelegate.toggleReadOnly),
                                      keyEquivalent: "")
        readOnlyItem.target = self
        let readOnlyAllItem = NSMenuItem(title: "Read-Only for All Documents",
                                         action: #selector(HexpadAppDelegate.toggleReadOnlyForAll),
                                         keyEquivalent: "")
        readOnlyAllItem.target = self
        readOnlyMenuItem = readOnlyItem
        readOnlyAllMenuItem = readOnlyAllItem
        editMenu.addItem(readOnlyItem)
        editMenu.addItem(readOnlyAllItem)
        return editMenu
    }

    /// Mirrors the focused document's read-only flag onto both Edit items.
    /// Called by menu validation and by the controller whenever the focused tab
    /// changes, so the checkmark is correct even before the menu next opens.
    func updateReadOnlyCheckmarks() {
        let on = activeController?.tabStore.selectedDocument?.isReadOnly == true
        let state: NSControl.StateValue = on ? .on : .off
        readOnlyMenuItem?.state = state
        readOnlyAllMenuItem?.state = state
    }

    /// Runs an Edit > Indent item against the focused window with the user's
    /// live tab policy.
    ///
    /// The menu item keeps the registry identifier in `representedObject`; the
    /// Preferences policy is encoded as the command parameter so macro replay
    /// reproduces the same indentation without the Kit reading app state.
    @objc private func performIndentCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let controller = indentTargetController else {
            return
        }
        let settings = IndentSettings(tabSize: controller.preferences.tabSize,
                                      useTabs: controller.preferences.useTabs)
        controller.performCommand(identifier: identifier, parameter: settings.parameter)
    }

    /// Runs an Edit > Insert > Date Time item against the focused window. The
    /// customized entry passes the live Settings pattern to the registry; the
    /// two fixed styles read only the clock.
    @objc func performDateInsertCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let controller = indentTargetController else { return }
        let parameter = identifier == "insert-datetime-custom"
            ? controller.preferences.dateFormatString
            : nil
        controller.performCommand(identifier: identifier, parameter: parameter)
    }

    /// The controller for the focused window, falling back to the main window
    /// and then any open Hexpad window when a panel owns key status.
    private var indentTargetController: MainWindowController? {
        if let controller = NSApp.keyWindow?.contentViewController as? MainWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.contentViewController as? MainWindowController {
            return controller
        }
        return NSApp.windows.lazy.compactMap { $0.contentViewController as? MainWindowController }.first
    }
}
