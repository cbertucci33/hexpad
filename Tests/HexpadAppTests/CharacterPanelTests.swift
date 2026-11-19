import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

final class CharacterPanelTests: XCTestCase {

    func testGridDataSourceForFont() {
        let font = NSFont.systemFont(ofSize: 13)
        let panel = CharacterPanelWindowController(font: font)
        XCTAssertFalse(panel.characters.isEmpty)
        XCTAssertTrue(panel.characters.contains { $0.character == "→" || $0.name.localizedCaseInsensitiveContains("arrow") })
        XCTAssertTrue(panel.characters.contains { (0x00A0...0x00FF).contains(UInt32($0.character.unicodeScalars.first!.value)) })
    }

    func testSearchFilterByNameSubstring() {
        let panel = CharacterPanelWindowController(font: NSFont.systemFont(ofSize: 13))
        panel.searchQuery = "arrow"
        XCTAssertFalse(panel.filteredCharacters.isEmpty)
        XCTAssertTrue(panel.filteredCharacters.allSatisfy { $0.name.localizedCaseInsensitiveContains("arrow") || String($0.character).localizedCaseInsensitiveContains("arrow") })
        panel.searchQuery = ""
        XCTAssertEqual(panel.filteredCharacters.count, panel.characters.count)
    }

    func testInsertIntoTextViewPath() {
        let panel = CharacterPanelWindowController(font: NSFont.systemFont(ofSize: 13))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let entry = panel.characters.first { $0.character == "→" } ?? panel.characters[0]
        panel.insertCharacter(entry, into: textView)
        XCTAssertTrue(textView.string.contains(String(entry.character)))
    }

    func testRecentsPersistenceRoundTrip() {
        let key = CharacterPanelWindowController.recentsUserDefaultsKey
        UserDefaults.standard.removeObject(forKey: key)
        let panel = CharacterPanelWindowController(font: NSFont.systemFont(ofSize: 13))
        let char: Character = "→"
        panel.addRecent(char)
        XCTAssertTrue(panel.recents.contains(char))

        let panel2 = CharacterPanelWindowController(font: NSFont.systemFont(ofSize: 13))
        XCTAssertTrue(panel2.recents.contains(char))
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testLifecycleInstantiation() {
        let panel = CharacterPanelWindowController()
        XCTAssertNotNil(panel.window)
        XCTAssertTrue(panel.window is NSPanel)
    }
}