import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure geometry/line math for the line-number gutter. Lives in HexpadKit so
/// it is unit-testable without AppKit. All functions derive from text
/// content — no constant row heights anywhere.
public enum GutterGeometry {

    /// 1-based logical line number containing `charIndex` (UTF-16 offsets).
    public static func logicalLine(of charIndex: Int, in text: String) -> Int {
        guard charIndex > 0 else { return 1 }
        let utf16 = text.utf16
        let end = min(charIndex, utf16.count)
        var line = 1
        for (offset, unit) in utf16.enumerated() where offset < end {
            if unit == 10 { line += 1 } // "\n"
        }
        return line
    }

    /// First UTF-16 character index of a 1-based logical line.
    public static func firstCharIndex(of line: Int, in text: String) -> Int {
        guard line > 1 else { return 0 }
        var index = 0
        var remaining = line - 1
        for unit in text.utf16 {
            index += 1
            if unit == 10 {
                remaining -= 1
                if remaining == 0 { break }
            }
        }
        return min(index, text.utf16.count)
    }

    /// Total number of logical lines in the text (a trailing newline starts
    /// a final empty line, matching editor conventions).
    public static func lineCount(in text: String) -> Int {
        logicalLine(of: text.utf16.count, in: text)
    }

    /// Converts a line's top Y in the (possibly flipped) text view into the
    /// gutter view's coordinate space. The gutter's height equals the clip
    /// view's height, so aligning tops aligns rows exactly.
    ///
    /// - Parameters:
    ///   - topY: line's rect origin Y in the text view's coordinate space.
    ///   - lineHeight: actual laid-out line height for that row.
    ///   - rowHeight: drawn glyph height of the number itself.
    ///   - viewHeight: gutter view height.
    ///   - flipped: whether the text view uses flipped coordinates (NSTextView does).
    public static func rowOriginY(textViewHeight: CGFloat, lineHeight: CGFloat, rowHeight: CGFloat,
                                  viewHeight: CGFloat, flipped: Bool, topY: CGFloat) -> CGFloat {
        if flipped {
            // Text view: y=0 is the first line's top. Our non-flipped view:
            // y=viewHeight is the top. Place the number's baseline row at the
            // same visual band as the line (top-aligned within its height).
            _ = textViewHeight // height equality is asserted by layout; kept for clarity
            return viewHeight - topY - rowHeight
        }
        return topY
    }
}
