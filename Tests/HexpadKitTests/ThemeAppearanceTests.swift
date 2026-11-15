import XCTest
import AppKit
@testable import HexpadKit

/// Guards the fix for white-on-white rendering: the theme must follow the
/// text view's effective appearance rather than always using the dark theme.
final class ThemeAppearanceTests: XCTestCase {

    func testLightAppearanceSelectsLightTheme() {
        guard let appearance = NSAppearance(named: .aqua) else {
            return XCTFail("aqua appearance unavailable")
        }
        let theme = HexpadTheme.forAppearance(appearance)
        XCTAssertEqual(theme.name, HexpadTheme.light.theme.name)
        XCTAssertEqual(theme.foreground, NSColor.black)
        XCTAssertEqual(theme.background, NSColor.white)
    }

    func testDarkAppearanceSelectsDarkTheme() {
        guard let appearance = NSAppearance(named: .darkAqua) else {
            return XCTFail("darkAqua appearance unavailable")
        }
        let theme = HexpadTheme.forAppearance(appearance)
        XCTAssertEqual(theme.name, HexpadTheme.dark.theme.name)
        XCTAssertEqual(theme.foreground, NSColor.white)
    }

    func testForegroundIsNotUsedAsItsOwnBackground() {
        // The defect produced white text on a white background. Every built-in
        // theme must keep the default foreground distinct from its background.
        guard let light = NSAppearance(named: .aqua),
              let dark = NSAppearance(named: .darkAqua) else {
            return XCTFail("standard appearances unavailable")
        }
        for appearance in [light, dark] {
            let theme = HexpadTheme.forAppearance(appearance)
            XCTAssertNotEqual(theme.foreground, theme.background)
        }
    }
}
