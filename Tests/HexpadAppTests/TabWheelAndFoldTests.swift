import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

final class TabWheelAndFoldTests: XCTestCase {

    private func makeBar(tabCount: Int = 3) -> (bar: TabBarView, store: TabStore) {
        let store = TabStore()
        for i in 0..<tabCount {
            store.addDocument(DocumentModel(text: "tab\(i)"))
        }
        store.selectedIndex = 0
        let bar = TabBarView(tabStore: store)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        bar.reloadTabs()
        return (bar, store)
    }

    private func scrollEvent(deltaY: CGFloat, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil,
                         units: .pixel,
                         wheelCount: 1,
                         wheel1: Int32(deltaY > 0 ? 10 : -10),
                         wheel2: 0,
                         wheel3: 0)!
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        cg.flags = flags
        return NSEvent(cgEvent: cg)!
    }

    func testCmdWheelSwitchesTabWithWrap() {
        let (bar, store) = makeBar(tabCount: 3)
        XCTAssertEqual(store.selectedIndex, 0)

        bar.scrollWheel(with: scrollEvent(deltaY: 1, modifiers: .command))
        XCTAssertEqual(store.selectedIndex, 1)

        bar.scrollWheel(with: scrollEvent(deltaY: 1, modifiers: .command))
        XCTAssertEqual(store.selectedIndex, 2)

        bar.scrollWheel(with: scrollEvent(deltaY: 1, modifiers: .command))
        XCTAssertEqual(store.selectedIndex, 0)

        bar.scrollWheel(with: scrollEvent(deltaY: -1, modifiers: .command))
        XCTAssertEqual(store.selectedIndex, 2)
    }

    func testOptionWheelMovesActiveTabWithoutWrap() {
        let (bar, store) = makeBar(tabCount: 3)
        store.selectedIndex = 1
        bar.reloadTabs()

        bar.scrollWheel(with: scrollEvent(deltaY: 1, modifiers: .option))
        XCTAssertEqual(store.selectedIndex, 2)
        XCTAssertEqual(store.documents.map(\.text), ["tab0", "tab2", "tab1"])

        bar.scrollWheel(with: scrollEvent(deltaY: 1, modifiers: .option))
        XCTAssertEqual(store.selectedIndex, 2)
        XCTAssertEqual(store.documents.map(\.text), ["tab0", "tab2", "tab1"])

        bar.scrollWheel(with: scrollEvent(deltaY: -1, modifiers: .option))
        XCTAssertEqual(store.selectedIndex, 1)
        XCTAssertEqual(store.documents.map(\.text), ["tab0", "tab1", "tab2"])
    }

    func testPlainWheelDoesNotChangeSelection() {
        let (bar, store) = makeBar(tabCount: 3)
        store.selectedIndex = 1
        bar.reloadTabs()
        let before = store.selectedIndex

        bar.scrollWheel(with: scrollEvent(deltaY: 5, modifiers: []))
        XCTAssertEqual(store.selectedIndex, before)

        bar.scrollWheel(with: scrollEvent(deltaY: -5, modifiers: []))
        XCTAssertEqual(store.selectedIndex, before)
    }

    private let nestedText = "func f() {\n    if true {\n        let x = 1\n    }\n    let y = 2\n}\n"

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        document.setLanguage("Swift")
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    private func markerPoint(forLine line: Int, x: CGFloat, in editor: EditorContainer) -> NSPoint? {
        let length = (editor.textView.string as NSString).length
        guard let row = LineNumberGutter.rows(in: editor.textView,
                                              characterRange: NSRange(location: 0, length: length))
            .first(where: { $0.line == line }) else { return nil }
        return NSPoint(x: x,
                       y: editor.ruler.bounds.height - row.topY - row.height / 2)
    }

    func testOptionClickCollapsesSubtree() {
        let (editor, _) = makeEditor(nestedText)
        guard let point = markerPoint(forLine: 1,
                                      x: LineNumberGutter.markerColumnWidth / 2,
                                      in: editor) else {
            return XCTFail("no laid-out row for line 1")
        }
        XCTAssertEqual(editor.foldModel?.collapsedRanges.count, 0)

        XCTAssertTrue(editor.ruler.handleFoldMarkerClick(at: point, modifierFlags: .option))
        XCTAssertGreaterThan(editor.foldModel?.collapsedRanges.count ?? 0, 1)
    }

    func testShiftClickExpandsSubtree() {
        let (editor, _) = makeEditor(nestedText)
        guard let point = markerPoint(forLine: 1,
                                      x: LineNumberGutter.markerColumnWidth / 2,
                                      in: editor) else {
            return XCTFail("no laid-out row for line 1")
        }
        _ = editor.collapseFoldSubtree(atLine: 1)
        XCTAssertGreaterThan(editor.foldModel?.collapsedRanges.count ?? 0, 0)

        XCTAssertTrue(editor.ruler.handleFoldMarkerClick(at: point, modifierFlags: .shift))
        XCTAssertEqual(editor.foldModel?.collapsedRanges.count, 0)
    }

    func testPlainClickStillTogglesSingleFold() {
        let (editor, _) = makeEditor(nestedText)
        guard let point = markerPoint(forLine: 1,
                                      x: LineNumberGutter.markerColumnWidth / 2,
                                      in: editor) else {
            return XCTFail("no laid-out row for line 1")
        }
        XCTAssertTrue(editor.ruler.handleFoldMarkerClick(at: point))
        XCTAssertEqual(editor.foldModel?.collapsedRanges.count, 1)
    }

    func testNoMenuKeyEquivalentCollidesWithStandardChords() {
        let menu = HexpadAppDelegate().buildMainMenu()

        func collect(_ m: NSMenu) -> [NSMenuItem] {
            var result: [NSMenuItem] = []
            for item in m.items {
                result.append(item)
                if let sub = item.submenu { result.append(contentsOf: collect(sub)) }
            }
            return result
        }

        var allItems: [NSMenuItem] = []
        for top in menu.items {
            if let sub = top.submenu { allItems.append(contentsOf: collect(sub)) }
        }

        for item in allItems {
            let key = item.keyEquivalent.lowercased()
            guard key == "h" || key == "m" || key == "g" else { continue }
            let mask = item.keyEquivalentModifierMask
            guard mask.contains(.command) else { continue }
            let isShiftG = (key == "g" && mask == [.command, .shift])
            if isShiftG { continue }
            guard mask == [.command] else { continue }

            let action = item.action
            let actionName = action?.description ?? ""
            let allowed: Bool
            switch key {
            case "h":
                allowed = actionName.lowercased().contains("hide")
            case "m":
                allowed = actionName.lowercased().contains("miniaturize")
            case "g":
                allowed = actionName.lowercased().contains("findnext")
            default:
                allowed = false
            }
            XCTAssertTrue(allowed,
                          "menu item '\(item.title)' uses cmd+\(key) but is not the standard command")
        }
    }
}
