import AppKit
import HexpadKit

extension HexpadAppDelegate {
    func makeEncodingMenu() -> NSMenu {
        // bytes, no transcoding) from "Convert to" (retarget the bytes the next
        // save writes). Items are nil-targeted so MainWindowController's
        // validation supplies enabled state and the current-encoding checkmarks.
        let encodingMenu = NSMenu(title: "Encoding")
        let encodingSections: [(title: String, action: Selector)] = [
            ("Encode in", #selector(MainWindowController.encodeIn(_:))),
            ("Convert to", #selector(MainWindowController.convertToEncoding(_:)))
        ]
        for section in encodingSections {
            let submenu = NSMenu(title: section.title)
            for option in MainWindowController.encodingOptions {
                let item = NSMenuItem(title: option.title, action: section.action, keyEquivalent: "")
                item.target = nil
                item.representedObject = option.name
                submenu.addItem(item)
            }
            let sectionItem = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            sectionItem.submenu = submenu
            encodingMenu.addItem(sectionItem)
        }

        // Notepad++-style "Character sets" group: one submenu per language group,
        // items encode the current buffer in the chosen charset. The charset
        // name rides along as representedObject, same as the sections above.
        let charsetsMenu = NSMenu(title: "Character sets")
        for group in EncodingDetective.characterSets {
            let groupMenu = NSMenu(title: group.group)
            for charset in group.charsets {
                let item = NSMenuItem(title: charset.title,
                                      action: #selector(MainWindowController.encodeIn(_:)),
                                      keyEquivalent: "")
                item.target = nil
                item.representedObject = charset.title
                groupMenu.addItem(item)
            }
            let groupItem = NSMenuItem(title: group.group, action: nil, keyEquivalent: "")
            groupItem.submenu = groupMenu
            charsetsMenu.addItem(groupItem)
        }
        let charsetsItem = NSMenuItem(title: "Character sets", action: nil, keyEquivalent: "")
        charsetsItem.submenu = charsetsMenu
        encodingMenu.addItem(charsetsItem)

        // EOL submenu lived in the model (convertEOL) but had no UI at all.
        encodingMenu.addItem(.separator())
        let eolMenu = NSMenu(title: "Line Endings")
        for (title, sel) in [("LF (Unix)", #selector(setEOLLF)),
                             ("CRLF (Windows)", #selector(setEOLCRLF)),
                             ("CR (Classic Mac)", #selector(setEOLCR))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            eolMenu.addItem(item)
        }
        let eolItem = NSMenuItem(title: "Line Endings", action: nil, keyEquivalent: "")
        eolItem.submenu = eolMenu
        encodingMenu.addItem(eolItem)
        return encodingMenu
    }
}
