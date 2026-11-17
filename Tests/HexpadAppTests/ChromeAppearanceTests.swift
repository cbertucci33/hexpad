import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Guards the chrome-theming invariant: every chrome view paints its layer
/// background from a dynamic system colour, so the CGColor must be re-resolved
/// when the effective appearance changes. A frozen snapshot is exactly the
/// defect that left the tab bar, gutter and status strip dark in Light
/// appearance while the editor and minimap repainted correctly.
final class ChromeAppearanceTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled],
                          backing: .buffered,
                          defer: false)
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    /// Expected layer colour for a system colour under a named appearance.
    private func expected(_ color: NSColor, _ name: NSAppearance.Name) -> CGColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    /// Hosts `view` in the test window and switches light -> dark through the
    /// window, which is what delivers the appearance change in the real app.
    private func assertBackgroundFollowsAppearance(_ view: NSView,
                                                   expectedLight: NSColor,
                                                   expectedDark: NSColor,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) {
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)

        window.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(view.layer?.backgroundColor, expected(expectedLight, .aqua),
                       "light appearance must resolve to the light system colour",
                       file: file, line: line)
        let light = view.layer?.backgroundColor

        window.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        XCTAssertNotEqual(view.layer?.backgroundColor, light,
                          "layer background must be re-resolved after switching to dark",
                          file: file, line: line)
        XCTAssertEqual(view.layer?.backgroundColor, expected(expectedDark, .darkAqua),
                       "dark appearance must resolve to the dark system colour",
                       file: file, line: line)
    }

    func testTabBarBackgroundReResolvesAfterAppearanceChange() {
        let bar = TabBarView(tabStore: TabStore())
        assertBackgroundFollowsAppearance(bar,
                                          expectedLight: .controlBackgroundColor,
                                          expectedDark: .controlBackgroundColor)
    }

    func testTabButtonBackgroundReResolvesAfterAppearanceChange() {
        let button = TabButton(doc: DocumentModel(text: ""),
                               index: 0,
                               tabWidth: 140,
                               tabHeight: 32)
        button.isSelected = false
        assertBackgroundFollowsAppearance(button,
                                          expectedLight: .controlBackgroundColor,
                                          expectedDark: .controlBackgroundColor)

        button.isSelected = true
        var selectedUnderDark = NSColor.selectedContentBackgroundColor.cgColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            selectedUnderDark = NSColor.selectedContentBackgroundColor.cgColor
        }
        XCTAssertEqual(button.layer?.backgroundColor,
                       selectedUnderDark,
                       "a selected tab keeps following the appearance")
    }

    func testGutterBackgroundReResolvesAfterAppearanceChange() {
        let gutter = LineNumberGutter(textView: nil)
        assertBackgroundFollowsAppearance(gutter,
                                          expectedLight: .windowBackgroundColor,
                                          expectedDark: .windowBackgroundColor)
    }

    func testStatusBarBackgroundReResolvesAfterAppearanceChange() {
        let bar = StatusBar()
        assertBackgroundFollowsAppearance(bar,
                                          expectedLight: .controlBackgroundColor,
                                          expectedDark: .controlBackgroundColor)
    }

    /// Root cause B: the stock NSButton title must be cleared, or the cell
    /// paints "Button" under the real tab caption (and AX reports it).
    func testTabButtonHasNoStockCellTitle() {
        let button = TabButton(doc: DocumentModel(text: ""),
                               index: 0,
                               tabWidth: 140,
                               tabHeight: 32)
        XCTAssertEqual(button.title, "")
        let labels = button.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.count, 1, "exactly one label per tab")
    }

    /// Root cause C: the window must opt into the compact toolbar style; the
    /// default automatic/unified style measures 66pt on macOS 26.
    func testMainWindowUsesCompactToolbarStyle() {
        let main = MainWindow()
        XCTAssertEqual(main.toolbarStyle, .unifiedCompact)
        XCTAssertNotNil(main.toolbar)
    }
}
