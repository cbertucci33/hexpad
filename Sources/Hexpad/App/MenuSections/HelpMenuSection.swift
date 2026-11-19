import AppKit
import HexpadKit

extension HexpadAppDelegate {
    /// Notepad++ ships Online Manual / Project Page / Community Forum links in
    /// its Help menu. The first two have macOS-appropriate targets here; the
    /// N++ forum is omitted because it would send our users to another
    /// project's community.
    ///
    /// The repo has no README yet, so the manual points at the Notepad++
    /// manual, which is the behaviour spec this editor follows.
    static let onlineManualURL = "https://npp-user-manual.org/"
    static let projectPageURL = "https://github.com/cbertucci33/hexpad"

    func makeHelpMenu() -> NSMenu {
        let helpMenu = NSMenu(title: "Help")
        let aboutHexpad = NSMenuItem(title: "About Hexpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        helpMenu.addItem(aboutHexpad)
        helpMenu.addItem(helpLinkItem(title: "Hexpad Online Manual",
                                      urlString: Self.onlineManualURL))
        helpMenu.addItem(helpLinkItem(title: "Hexpad Project Page",
                                      urlString: Self.projectPageURL))
        let debugInfo = NSMenuItem(title: "Debug Info…",
                                  action: #selector(showDebugInfo),
                                  keyEquivalent: "")
        debugInfo.target = self
        helpMenu.addItem(debugInfo)
        let commandLineArguments = NSMenuItem(title: "Command Line Arguments…",
                                             action: #selector(showCommandLineArguments),
                                             keyEquivalent: "")
        commandLineArguments.target = self
        helpMenu.addItem(commandLineArguments)
        return helpMenu
    }

    /// Browser links carry their URL in `representedObject`, so the shared
    /// action stays stateless. A URL that fails to parse leaves the item
    /// disabled instead of appearing to work and doing nothing.
    private func helpLinkItem(title: String, urlString: String) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(openHelpLink(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = URL(string: urlString)
        item.isEnabled = item.representedObject != nil
        return item
    }
}
