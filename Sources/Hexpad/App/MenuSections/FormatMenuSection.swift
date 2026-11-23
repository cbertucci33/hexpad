import AppKit

extension HexpadAppDelegate {
    func makeFormatMenu() -> NSMenu {
        let formatMenu = NSMenu(title: "Format")
        let showFontsItem = NSMenuItem(title: "Show Fonts",
                                       action: #selector(NSFontManager.orderFrontFontPanel(_:)),
                                       keyEquivalent: "t")
        showFontsItem.keyEquivalentModifierMask = [.command, .shift]
        showFontsItem.target = NSFontManager.shared
        formatMenu.addItem(showFontsItem)
        return formatMenu
    }
}
