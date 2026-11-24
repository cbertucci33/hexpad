import AppKit

/// Live Notepad++-style brace highlighting: outlines the bracket next to the
/// caret and its partner, or paints a "bad brace" outline when the bracket has
/// no partner.
///
/// The marks are temporary attributes on the layout manager under a private
/// key, exactly like the token-style and find overlays, so the syntax
/// highlighter's text-storage attributes are never touched and nothing is
/// persisted or undoable. The view is a transparent, click-through child of
/// the text view; drawing in text-view coordinates makes the boxes scroll and
/// zoom with the glyphs without a timer or scroll observer.
final class BraceHighlight: NSView {

    /// One highlight flush: the bracket ranges to outline and which tone to use.
    struct Highlight: Equatable {
        enum Style: Int, Equatable {
            case match
            case unmatched
        }

        let ranges: [NSRange]
        let style: Style
    }

    /// Temporary-attribute key carrying the ``Highlight/Style`` raw value.
    /// Private so the find and incremental-search overlays, which own
    /// `.backgroundColor`, cannot collide with or clear these marks.
    static let attributeKey = NSAttributedString.Key("HexpadBraceHighlight")

    /// N++'s "Brace Highlight" accent and its red "bad brace" counterpart.
    /// Both are dynamic system colours, so one constant follows light/dark
    /// appearance without re-resolving.
    static let matchColor = NSColor.systemIndigo
    static let unmatchedColor = NSColor.systemRed

    private weak var textView: NSTextView?
    private(set) var highlight: Highlight?
    private var markedRanges: [NSRange] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: textView.bounds)
        autoresizingMask = [.width, .height]
        textView.addSubview(self, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Overlays must never steal clicks or drags from the text view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    /// Match the text view's flipped coordinate system so glyph rectangles can
    /// be drawn at their layout-manager positions unchanged.
    override var isFlipped: Bool { textView?.isFlipped ?? true }

    override func layout() {
        super.layout()
        syncFrameToTextView()
    }

    /// Adopts a new highlight (or clears it) in one step. The previous marks
    /// are always removed before the new ones are added, so a stale partner
    /// can never survive a caret move.
    func show(_ highlight: Highlight?) {
        guard highlight != self.highlight else { return }
        clearMarks()
        self.highlight = highlight
        syncFrameToTextView()

        if let highlight, let layoutManager = textView?.layoutManager {
            for range in highlight.ranges where range.length > 0 {
                layoutManager.addTemporaryAttributes(
                    [Self.attributeKey: NSNumber(value: highlight.style.rawValue)],
                    forCharacterRange: range
                )
            }
            markedRanges = highlight.ranges.filter { $0.length > 0 }
        }
        needsDisplay = true
    }

    func clear() {
        show(nil)
    }

    /// The text view grows with its buffer; keep the overlay's clip region in
    /// step even when no selection change follows a resize.
    func syncFrameToTextView() {
        guard let textView, frame != textView.bounds else { return }
        frame = textView.bounds
    }

    private func clearMarks() {
        defer { markedRanges = [] }
        guard let layoutManager = textView?.layoutManager,
              let storage = layoutManager.textStorage else { return }
        let buffer = NSRange(location: 0, length: storage.length)
        for range in markedRanges {
            let clamped = NSIntersectionRange(range, buffer)
            guard clamped.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(Self.attributeKey,
                                                   forCharacterRange: clamped)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let highlight,
              let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              !highlight.ranges.isEmpty else { return }

        let color = highlight.style == .match ? Self.matchColor : Self.unmatchedColor
        color.setStroke()
        let origin = textView.textContainerOrigin

        for range in highlight.ranges where range.length > 0 {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                // A hair of inset gives the bracket breathing room instead of
                // clipping its glyph; tiny fragments still get a visible box.
                var box = rect.offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -1, dy: -0.5)
                box.size.width = max(box.width, 3)
                box.size.height = max(box.height, 3)
                guard box.intersects(dirtyRect) else { return }
                let path = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}
