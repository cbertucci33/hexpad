import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Guards the editor's most destructive rendering failure: a minimap repaint
/// that reaches outside the minimap's own frame erases the gutter and the text
/// view, leaving a correct buffer with no visible glyphs.
final class MinimapDrawingTests: XCTestCase {

    /// AppKit forwards a full-window invalidation to every subview without
    /// intersecting it with that subview's frame, so `draw(_:)` can be handed a
    /// dirty rect that starts left of the view and covers the whole container.
    /// The minimap paints its dirty band opaquely, so it must never paint
    /// outside its own bounds.
    func testMinimapDrawNeverPaintsLeftOfItsOwnFrame() throws {
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        editor.setMinimapVisible(true)
        let document = DocumentModel(text: "let a = 1\nlet b = 2\nlet c = 3")
        editor.bind(to: document)
        editor.layout()

        let minimap = editor.minimap
        XCTAssertFalse(minimap.isHidden)
        XCTAssertGreaterThan(minimap.frame.minX, 0)

        // The same shape AppKit supplies for a whole-window invalidation: it
        // starts at the container's leading edge, far left of the minimap.
        let oversized = NSRect(x: -minimap.frame.minX,
                               y: -32,
                               width: editor.bounds.width,
                               height: editor.bounds.height + 32)

        let width = Int(editor.bounds.width)
        let height = Int(editor.bounds.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: width,
                                                 pixelsHigh: height,
                                                 bitsPerSample: 8,
                                                 samplesPerPixel: 4,
                                                 hasAlpha: true,
                                                 isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: width * 4,
                                                 bitsPerPixel: 32))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Sentinel: anything the minimap paints shows up as a non-magenta pixel.
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Draw the minimap at the position its frame gives it in the container,
        // with the oversized dirty rect AppKit would pass.
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: minimap.frame.minX, y: minimap.frame.minY)
        minimap.draw(oversized)
        context.cgContext.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let leftEdge = Int(minimap.frame.minX)
        var paintedOutside = 0
        for y in stride(from: 2, to: height, by: 7) {
            for x in stride(from: 2, to: leftEdge, by: 7) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    paintedOutside += 1
                    continue
                }
                let isSentinel = color.redComponent > 0.9
                    && color.greenComponent < 0.2
                    && color.blueComponent > 0.9
                if !isSentinel { paintedOutside += 1 }
            }
        }

        XCTAssertEqual(paintedOutside, 0,
                       "a minimap repaint must not paint over the editor to its left")
    }
}
