import CoreGraphics
import Foundation

/// Per-document editor state that should survive a session restart.
///
/// This is deliberately a plain value type with no AppKit or TextKit
/// behaviour. `DocumentModel` carries and persists these values; the app's
/// editor container owns applying them to its text view and scroll view.
/// Keeping the live TextKit objects out of the model avoids a second source
/// of truth for selection and scroll geometry.
public struct DocumentEditorState: Equatable {

    /// Selected range in the document's UTF-16 buffer. A zero-length range is
    /// a bare caret.
    public var caretRange: NSRange

    /// Scroll view content origin at the moment the state was captured.
    public var scrollOffset: CGPoint

    /// Whether the editor soft-wraps long lines. The app maps this to
    /// `NSTextView.isHorizontallyResizable` (inverted).
    public var wordWrapEnabled: Bool

    /// Editor zoom as a multiplier of the base font size (1.0 = 100%).
    public var zoomScale: CGFloat

    /// Restored defaults. These intentionally match the app's startup state,
    /// so a session written before per-document editor state existed restores
    /// exactly as it did previously.
    public static let `default` = DocumentEditorState()

    public init(caretRange: NSRange = NSRange(location: 0, length: 0),
                scrollOffset: CGPoint = .zero,
                wordWrapEnabled: Bool = false,
                zoomScale: CGFloat = 1.0) {
        self.caretRange = caretRange
        self.scrollOffset = scrollOffset
        self.wordWrapEnabled = wordWrapEnabled
        self.zoomScale = zoomScale
    }
}

// MARK: - Session persistence

extension DocumentEditorState {

    /// JSON-ready representation, nested under a single `editorState` key in
    /// the document's session dictionary. A session file written before this
    /// slice simply lacks that key and restores as `.default`.
    func toSessionData() -> [String: Any] {
        [
            "caretLocation": max(0, caretRange.location),
            "caretLength": max(0, caretRange.length),
            "scrollX": Double(scrollOffset.x),
            "scrollY": Double(scrollOffset.y),
            "wordWrap": wordWrapEnabled,
            "zoomScale": Double(zoomScale)
        ]
    }

    /// Missing or malformed keys fall back to defaults individually, so a
    /// partially written state (or a future version that adds another field)
    /// still restores everything it understands.
    static func fromSessionData(_ data: [String: Any]?) -> DocumentEditorState {
        guard let data else { return .default }

        var state = DocumentEditorState()

        if let location = intValue(data["caretLocation"]), location >= 0 {
            let length = max(0, intValue(data["caretLength"]) ?? 0)
            state.caretRange = NSRange(location: location, length: length)
        }

        let x = doubleValue(data["scrollX"]) ?? 0
        let y = doubleValue(data["scrollY"]) ?? 0
        if x.isFinite, y.isFinite {
            state.scrollOffset = CGPoint(x: x, y: y)
        }

        if let wrap = data["wordWrap"] as? Bool {
            state.wordWrapEnabled = wrap
        }

        if let scale = doubleValue(data["zoomScale"]), scale.isFinite, scale > 0 {
            state.zoomScale = CGFloat(scale)
        }

        return state
    }

    // JSONSerialization hands numbers back as NSNumber; tests and callers may
    // also supply native Swift numbers. Accept both.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        return (value as? NSNumber)?.doubleValue
    }
}
