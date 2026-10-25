import AppKit
import HexpadKit

/// Vertical line-number gutter drawn from real text-layout geometry.
///
/// Every line number's Y position is derived from the layout manager's
/// line-fragment rects (TextKit 1) or text-segment layout rects (TextKit 2),
/// never from a constant row height. Redraw is driven by scroll (clip-bounds
/// change), resize (frame change), text mutation, and font/zoom changes.
final class LineNumberGutter: NSView {

    /// Kept as NSRulerView for wiring compatibility; this view draws itself.
    static let width: CGFloat = 40

    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []
    private var fontObservation: NSKeyValueObservation?
    private var clickHandler: ((Int) -> Void)?

    init(textView: NSTextView?) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// Passes the clicked character index (already resolved through layout)
    /// so callers don't divide pixel positions by magic numbers.
    func setClickHandler(_ handler: ((Int) -> Void)?) {
        clickHandler = handler
    }

    // MARK: - Redraw triggers

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard window != nil, let textView else { return }

        let center = NotificationCenter.default
        let watch = { (object: Any?, name: NSNotification.Name) in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
        if let clip = textView.enclosingScrollView?.contentView {
            // Continuous scroll: clip bounds change with every pixel.
            clip.postsBoundsChangedNotifications = true
            observers.append(watch(clip, NSView.boundsDidChangeNotification))
        }
        observers.append(watch(textView.enclosingScrollView, NSView.frameDidChangeNotification))
        observers.append(watch(textView, NSView.frameDidChangeNotification))
        observers.append(watch(textView.textStorage, NSTextStorage.didProcessEditingNotification))
        observers.append(watch(textView.layoutManager,
                               NSNotification.Name("NSLayoutManagerDidInvalidateLayoutNotification")))
        // Zoom mutates textView.font directly; KVO guarantees a redraw on any
        // font change (legacy layoutManager invalidation is async and unreliable).
        fontObservation = textView.observe(\.font, options: [.initial, .new]) { [weak self] _, _ in
            self?.needsDisplay = true
        }
    }

    // MARK: - Drawing

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // App runs on TextKit 1 (NSTextView default): layoutManager is live.
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let font = numberFont(for: textView)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        drawTextKit1(in: textView, layoutManager: layoutManager, attributes: attributes)
    }

    private func numberFont(for textView: NSTextView) -> NSFont {
        // Scale gutter type with editor zoom so rows stay visually 1:1.
        let size = max(8, min(14, (textView.font?.pointSize ?? 13) * 0.75))
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func drawTextKit1(in textView: NSTextView,
                             layoutManager: NSLayoutManager,
                             attributes: [NSAttributedString.Key: Any]) {
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textView.textContainer!)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }

        let text = textView.string
        var lastDrawnLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] fragmentRect, _, _, fragmentCharRange, _ in
            guard let self else { return }
            let line = GutterGeometry.logicalLine(of: fragmentCharRange.location, in: text)
            guard line != lastDrawnLine else { return } // wrapped visual line: draw once
            lastDrawnLine = line
            self.drawNumber("\(line)", atTopY: fragmentRect.minY, height: fragmentRect.height,
                            textView: textView, attributes: attributes)
        }
    }

    /// Draws a right-aligned number + tick at the left edge of a line's actual
    /// layout rect. Converts text-view (flipped) Y to this view's geometry.
    private func drawNumber(_ string: String, atTopY topY: CGFloat, height: CGFloat,
                            textView: NSTextView, attributes: [NSAttributedString.Key: Any]) {
        let size = string.size(withAttributes: attributes)
        let y = GutterGeometry.rowOriginY(textViewHeight: textView.bounds.height,
                                          lineHeight: height,
                                          rowHeight: size.height,
                                          viewHeight: bounds.height,
                                          flipped: textView.isFlipped,
                                          topY: topY)
        let x = bounds.width - size.width - 6
        string.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)

        NSColor.separatorColor.setStroke()
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: bounds.width - 4, y: y))
        tick.line(to: NSPoint(x: bounds.width, y: y))
        tick.lineWidth = 1
        tick.stroke()
    }

    // MARK: - Click

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        // Our bounds are the same height as the clip view and we sit beside it;
        // map click Y straight into text-view coordinates.
        let p = convert(event.locationInWindow, from: nil)
        let textY = bounds.height - p.y // we are non-flipped, text view is flipped
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: NSPoint(x: 0, y: textY),
                                                in: container,
                                                fractionOfDistanceBetweenInsertionPoints: &fraction)
        clickHandler?(index)
    }
}
