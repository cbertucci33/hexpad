import XCTest
import AppKit
@testable import HexpadKit

final class TabColorTests: XCTestCase {

    private let light = NSAppearance(named: .aqua)
    private let dark = NSAppearance(named: .darkAqua)

    // MARK: - Palette

    func testPaletteHasFiveColorsAndRejectsOutOfRangeIndexes() {
        XCTAssertEqual(TabColorPalette.colorCount, 5)

        for index in 1...TabColorPalette.colorCount {
            XCTAssertNotNil(TabColorPalette.color(for: index, appearance: light))
            XCTAssertNotNil(TabColorPalette.color(for: index, appearance: dark))
        }
        XCTAssertNil(TabColorPalette.color(for: 0, appearance: light))
        XCTAssertNil(TabColorPalette.color(for: 6, appearance: light))
    }

    func testPaletteIsStableForTheSameAppearance() {
        let first = TabColorPalette.colors(for: light)
        let second = TabColorPalette.colors(for: light)

        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(first, second, "the palette must not drift between draws")
        XCTAssertEqual(TabColorPalette.colors(for: nil), first,
                       "an unknown appearance falls back to the light palette")
    }

    func testFiveColorsAreDistinctInEachAppearance() {
        for appearance in [light, dark] {
            let colors = TabColorPalette.colors(for: appearance)
                .compactMap { $0.usingColorSpace(.deviceRGB) }
            XCTAssertEqual(colors.count, 5)

            for (offset, color) in colors.enumerated() {
                for other in colors[(offset + 1)...] {
                    XCTAssertNotEqual(color.hueComponent, other.hueComponent,
                                      accuracy: 0.001,
                                      "the hue rotation gives each slot its own colour")
                }
            }
        }
    }

    func testLightAndDarkPalettesDifferInBrightness() {
        let lightColor = TabColorPalette.color(for: 1, appearance: light)?
            .usingColorSpace(.deviceRGB)
        let darkColor = TabColorPalette.color(for: 1, appearance: dark)?
            .usingColorSpace(.deviceRGB)

        XCTAssertNotNil(lightColor)
        XCTAssertNotNil(darkColor)
        XCTAssertGreaterThan(darkColor?.brightnessComponent ?? 0,
                             lightColor?.brightnessComponent ?? 1)
    }

    // MARK: - Session

    private func makeDocument() -> DocumentModel {
        let doc = DocumentModel(text: "hello")
        doc.name = "sample.txt"
        return doc
    }

    func testTabColorRoundTripsThroughDocumentSession() {
        let doc = makeDocument()
        doc.tabColorIndex = 3

        let restored = DocumentModel.fromSessionData(doc.toSessionData())
        XCTAssertEqual(restored?.tabColorIndex, 3)
    }

    func testUncolouredDocumentRoundTripsAsNil() {
        let doc = makeDocument()
        doc.tabColorIndex = nil

        let restored = DocumentModel.fromSessionData(doc.toSessionData())
        XCTAssertNil(restored?.tabColorIndex)
        XCTAssertNil(doc.toSessionData()["tabColorIndex"],
                     "an uncoloured tab stores no key at all")
    }

    func testOutOfRangeSessionColorIsIgnored() {
        let doc = makeDocument()
        var data = doc.toSessionData()
        data["tabColorIndex"] = 9

        let restored = DocumentModel.fromSessionData(data)
        XCTAssertNil(restored?.tabColorIndex)
    }

    func testSessionColorSurvivesRemovingItAgain() {
        let doc = makeDocument()
        doc.tabColorIndex = 5
        doc.tabColorIndex = nil

        let restored = DocumentModel.fromSessionData(doc.toSessionData())
        XCTAssertNil(restored?.tabColorIndex)
    }
}
