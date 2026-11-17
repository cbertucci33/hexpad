import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeLanguageMenu() -> NSMenu {
        let languageMenu = NSMenu(title: "Language")
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.rawValue, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Language.allCases.firstIndex(of: lang) ?? 0
            languageMenu.addItem(item)
        }
        return languageMenu
    }
}
