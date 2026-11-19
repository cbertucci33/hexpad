import AppKit
import HexpadKit

/// Presentation state of a fold marker on one gutter line.
enum FoldMarkerState: Equatable {
    /// The fold is collapsed: content below the fold's first line is hidden.
    case collapsed

    /// The fold is expanded: the whole construct is drawn.
    case expanded

    /// Glyph the gutter draws for this state. `nil` lines draw nothing.
    var glyph: String {
        switch self {
        case .collapsed: return "▸"
        case .expanded: return "▾"
        }
    }
}

/// Derives gutter markers from a ``FoldModel``.
///
/// Markers are presentation, not state: the fold model remains the source of
/// truth for which ranges are foldable and which are collapsed. Keeping the
/// line mapping here (instead of inside the gutter) lets the editor container
/// and the gutter agree on exactly one marker per line without duplicating the
/// 1-based logical line math.
enum FoldMargin {

    /// One marker per logical line that starts a foldable range.
    ///
    /// `FoldModel.foldableRanges` sorts outer ranges before nested ranges at the
    /// same offset, so the first fold seen for a line is the one a gutter marker
    /// represents. Nesting deeper on the same line is still foldable through the
    /// model; it just shares the outer marker.
    static func markers(for model: FoldModel?) -> [Int: FoldMarkerState] {
        guard let model else { return [:] }

        var markers: [Int: FoldMarkerState] = [:]
        for fold in model.foldableRanges {
            let line = GutterGeometry.logicalLine(of: fold.location, in: model.text)
            guard markers[line] == nil else { continue }
            markers[line] = model.isCollapsed(fold) ? .collapsed : .expanded
        }
        return markers
    }
}

/// Hides collapsed fold content and explicitly hidden lines from text layout
/// without touching the text storage.
///
/// The editor's incremental highlighting pipeline owns character attributes on
/// `DocumentModel.textStorage`. Zero-width fonts or clear foreground colours
/// would be overwritten by the next highlight pass, and replacing the storage
/// would break the shared buffer. Instead this layout-manager delegate swaps
/// the glyphs of hidden characters for null glyphs: layout gives them zero
/// advance and skips their line breaks, so folded or hidden lines disappear
/// from the rendered document while the model, tokenizer, selections, and undo
/// stack all keep operating on the full text.
///
/// Two independent masks share the delegate — one from ``FoldVisibility``, one
/// from ``HideLinesVisibility`` — because the editor must be able to hide a
/// fold and a user-hidden block at the same time. ``hiddenRanges`` is their
/// merged effective set; ``foldHiddenRanges`` keeps the fold mask separate for
/// callers that ask about folds specifically.
///
/// Call `setFoldHiddenRanges(_:)` / `setLineHiddenRanges(_:)` and then
/// invalidate glyphs/layout for the affected range (the editor container does
/// both).
final class FoldGlyphHider: NSObject, NSLayoutManagerDelegate {

    /// Document ranges whose glyphs layout suppresses because their fold is
    /// collapsed. Sorted, non-overlapping.
    private(set) var foldHiddenRanges: [NSRange] = []

    /// Document ranges whose glyphs layout suppresses because the user hid the
    /// lines (View > Hide Lines). Sorted, non-overlapping.
    private(set) var lineHiddenRanges: [NSRange] = []

    /// Effective hidden set: both masks merged. Sorted, non-overlapping.
    private(set) var hiddenRanges: [NSRange] = []

    /// Replaces the fold mask.
    ///
    /// - Returns: `true` when the effective hidden set changed, so callers can
    ///   skip a full layout invalidation when a fold toggle leaves visibility
    ///   alone.
    @discardableResult
    func setHiddenRanges(_ ranges: [NSRange]) -> Bool {
        setFoldHiddenRanges(ranges)
    }

    /// Replaces the fold mask. Kept separate from the hidden-lines mask so each
    /// owner can update its own ranges without clobbering the other's.
    @discardableResult
    func setFoldHiddenRanges(_ ranges: [NSRange]) -> Bool {
        let sorted = FoldGlyphHider.normalized(ranges)
        guard sorted != foldHiddenRanges else { return false }
        foldHiddenRanges = sorted
        return rebuildEffectiveRanges()
    }

    /// Replaces the user-hidden-lines mask.
    @discardableResult
    func setLineHiddenRanges(_ ranges: [NSRange]) -> Bool {
        let sorted = FoldGlyphHider.normalized(ranges)
        guard sorted != lineHiddenRanges else { return false }
        lineHiddenRanges = sorted
        return rebuildEffectiveRanges()
    }

    /// Whether the character at `characterIndex` is hidden by a collapsed fold
    /// or by a hidden line.
    func isHidden(characterIndex: Int) -> Bool {
        hiddenRanges.contains { range in
            range.location <= characterIndex && characterIndex < NSMaxRange(range)
        }
    }

    private func rebuildEffectiveRanges() -> Bool {
        let before = hiddenRanges
        hiddenRanges = FoldGlyphHider.merged(foldHiddenRanges + lineHiddenRanges)
        return hiddenRanges != before
    }

    private static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        ranges.filter { $0.length > 0 }.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length < rhs.length
        }
    }

    /// Merges touching and overlapping ranges so the glyph loop checks the
    /// smallest possible set (fold and hide masks often overlap exactly).
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in normalized(ranges) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                result[result.count - 1] = NSRange(location: last.location,
                                                   length: end - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty, glyphRange.length > 0 else { return 0 }

        var newGlyphs = [CGGlyph]()
        var newProperties = [NSLayoutManager.GlyphProperty]()
        newGlyphs.reserveCapacity(glyphRange.length)
        newProperties.reserveCapacity(glyphRange.length)

        var changedAny = false
        for offset in 0..<glyphRange.length {
            if isHidden(characterIndex: charIndexes[offset]) {
                // NSNullGlyph: no advance, no drawing, and a hidden newline does
                // not start a new line fragment.
                newGlyphs.append(0)
                newProperties.append(.null)
                changedAny = true
            } else {
                newGlyphs.append(glyphs[offset])
                newProperties.append(props[offset])
            }
        }

        guard changedAny else { return 0 }
        layoutManager.setGlyphs(newGlyphs,
                                properties: newProperties,
                                characterIndexes: charIndexes,
                                font: aFont,
                                forGlyphRange: glyphRange)
        return glyphRange.length
    }
}

/// Hidden-lines state plus the live line count, handed to the gutter in one
/// pull so a draw pass never rescans the document to number its rows.
struct HiddenLinesPresentation {
    let state: HideLinesState
    let lineCount: Int

    static let empty = HiddenLinesPresentation(state: HideLinesState(), lineCount: 0)
}

/// Vertical line-number gutter drawn from real text-layout geometry.
///
/// Every line number's Y position is derived from the layout manager's
/// line-fragment rects (TextKit 1) or text-segment layout rects (TextKit 2),
/// never from a constant row height. Redraw is driven by scroll (clip-bounds
/// change), resize (frame change), text mutation, and font/zoom changes.
///
/// The gutter also owns the fold margin: a narrow leading column that draws one
/// ▸/▾ marker per foldable line, followed by a bookmark margin that draws a
/// Notepad++-style filled circle on bookmarked lines. Integrating it here
/// (rather than adding a second sibling view) keeps one source of
/// scroll/zoom/text invalidation and one mapping from mouse Y to a logical line;
/// the line-number column keeps its exact previous drawing and click behavior.
final class LineNumberGutter: NSView {

    /// Right-aligned line-number column, including the bookmark margin.
    ///
    /// The bookmark margin shares this slot so the gutter's historical
    /// `markerColumnWidth + numberColumnWidth` total width identity is kept.
    static let numberColumnWidth: CGFloat = 54

    /// Width the digits themselves occupy at the trailing edge.
    static let digitColumnWidth: CGFloat = 40

    /// Leading fold-marker column.
    static let markerColumnWidth: CGFloat = 16

    /// Bookmark-margin column, immediately right of the fold markers.
    static let bookmarkColumnWidth: CGFloat = 14

    /// Total gutter width: marker column plus number column.
    static let width: CGFloat = numberColumnWidth + markerColumnWidth

    /// One laid-out gutter row: the first visual fragment of a logical line.
    struct Row: Equatable {
        /// 1-based logical line number.
        let line: Int
        /// Line-fragment top Y in text-view (flipped) coordinates.
        let topY: CGFloat
        /// Laid-out line-fragment height.
        let height: CGFloat
    }

    private weak var textView: NSTextView?
    private var observers: [NSObjectProtocol] = []
    private var fontObservation: NSKeyValueObservation?
    /// Called with the clicked character index (already resolved through the
    /// layout) plus the anchor index a press started from — equal to the clicked
    /// index on a plain click — so the caller can select a whole line or extend
    /// a drag across lines without any pixel math of its own.
    private var clickHandler: ((Int, Int) -> Void)?

    /// Supplies fold markers at draw and click time. Pulling instead of pushing
    /// lets the editor container lazily refresh its fold model before the gutter
    /// paints, so markers never lag one edit behind.
    var foldMarkersProvider: (() -> [Int: FoldMarkerState])?

    /// Called with the 1-based logical line whose fold marker was clicked.
    var onToggleFold: ((Int) -> Void)?

    /// Called with the 1-based logical line whose fold marker was clicked with
    /// Shift held: expands that fold and every fold nested inside it.
    var onExpandFoldSubtree: ((Int) -> Void)?

    /// Called with the 1-based logical line whose fold marker was clicked with
    /// Option held: collapses that fold and every fold nested inside it.
    var onCollapseFoldSubtree: ((Int) -> Void)?

    /// Supplies the bookmarked logical lines at draw time. Like the fold
    /// provider this is pulled, so a remap that happened during the edit is
    /// already reflected when the redraw runs.
    var bookmarkLinesProvider: (() -> Set<Int>)?

    /// Called with the 1-based logical line whose bookmark margin was clicked.
    var onToggleBookmark: ((Int) -> Void)?

    /// Supplies the hidden-lines state and line count at draw time so the
    /// gutter can renumber visible rows and place unhide symbols. Pulled like
    /// the other providers: the container refreshes its per-document state
    /// first.
    var hiddenLinesProvider: (() -> HiddenLinesPresentation)?

    /// Anchor logical line → the hidden line range it represents. Hidden rows
    /// have no layout of their own, so a range's symbol is drawn on the last
    /// visible line above it (or the first visible line below when the range
    /// starts at line 1).
    var hiddenRangeMarkersProvider: (() -> [Int: ClosedRange<Int>])?

    /// Called with the hidden line range whose margin symbol was clicked.
    var onUnhideHiddenRange: ((ClosedRange<Int>) -> Void)?

    /// Character index where the current gutter drag started; drives
    /// click-and-drag line selection.
    private var dragAnchorCharIndex: Int?

    init(textView: NSTextView?) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        refreshChromeColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        refreshChromeColors()
    }

    /// Re-resolves the gutter background for the current appearance. A CGColor
    /// snapshot keeps the launch-time light/dark value, which made the rail
    /// stay black in Light appearance while the text view beside it repainted.
    func refreshChromeColors() {
        layer?.backgroundColor = ChromeColor.cgColor(.windowBackgroundColor,
                                                     for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
        needsDisplay = true
    }

    /// Passes the clicked character index (already resolved through layout)
    /// plus the anchor index a press started from, so callers don't divide pixel
    /// positions by magic numbers and can extend a drag across lines.
    func setClickHandler(_ handler: ((Int, Int) -> Void)?) {
        clickHandler = handler
    }

    /// Marker currently shown for a logical line, if any.
    func markerState(forLine line: Int) -> FoldMarkerState? {
        foldMarkersProvider?()[line]
    }

    /// Whether `line` currently carries a bookmark marker.
    func isBookmarked(line: Int) -> Bool {
        bookmarkLinesProvider?().contains(line) ?? false
    }

    // MARK: - Redraw triggers

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshObservers()
    }

    /// Re-subscribes to the editor's current text storage. The container swaps
    /// the shared buffer when a tab is bound, so the storage captured when the
    /// view attached to its window is stale after the first tab switch.
    func textStorageDidChange() {
        guard window != nil else { return }
        refreshObservers()
    }

    private func refreshObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        fontObservation = nil
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
            // tertiaryLabelColor resolves to ~26% black in Light appearance,
            // which is too faint for 10pt digits on the now-light rail.
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let rows = Self.rows(in: textView)
        let markers = foldMarkersProvider?() ?? [:]
        let bookmarkedLines = bookmarkLinesProvider?() ?? []
        let hidden = hiddenLinesProvider?() ?? .empty
        let hiddenMarkers = hiddenRangeMarkersProvider?() ?? [:]
        for row in rows {
            // Hiding renumbers the visible rows: the line after a hidden block
            // takes the next number instead of skipping. Bookmarks and fold
            // markers still key on `row.line`, the document line.
            let number = hidden.state.displayNumber(forLine: row.line,
                                                   lineCount: hidden.lineCount)
            if let number {
                drawNumber("\(number)", atTopY: row.topY, height: row.height,
                           textView: textView, attributes: attributes)
            }
            if let marker = markers[row.line] {
                drawMarker(marker, atTopY: row.topY, height: row.height, textView: textView)
            }
            if bookmarkedLines.contains(row.line) {
                drawBookmark(atTopY: row.topY, height: row.height, textView: textView)
            }
            if hiddenMarkers[row.line] != nil {
                drawHiddenRangeMarker(atTopY: row.topY, height: row.height, textView: textView)
            }
        }
    }

    private func numberFont(for textView: NSTextView) -> NSFont {
        // Scale gutter type with editor zoom so rows stay visually 1:1.
        let size = max(8, min(14, (textView.font?.pointSize ?? 13) * 0.75))
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The logical rows a gutter pass draws, in layout order.
    ///
    /// Shared by drawing and tests so line numbering has one implementation.
    /// Pass `characterRange` to force a range (tests); omit it to use the
    /// text view's visible rect.
    static func rows(in textView: NSTextView, characterRange: NSRange? = nil) -> [Row] {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return [] }

        let glyphRange: NSRange
        if let characterRange {
            let textLength = (textView.string as NSString).length
            let location = min(max(0, characterRange.location), textLength)
            let length = min(max(0, characterRange.length), textLength - location)
            let clamped = NSRange(location: location, length: length)
            guard clamped.length > 0 else { return [] }
            glyphRange = layoutManager.glyphRange(forCharacterRange: clamped,
                                                  actualCharacterRange: nil)
        } else {
            glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect,
                                                  in: container)
        }
        guard glyphRange.length > 0 else { return [] }

        let text = textView.string
        var rows: [Row] = []
        var lastDrawnLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            fragmentRect, _, _, fragmentCharRange, _ in
            let line = GutterGeometry.logicalLine(of: fragmentCharRange.location, in: text)
            guard line != lastDrawnLine else { return } // wrapped visual line: draw once
            lastDrawnLine = line
            rows.append(Row(line: line, topY: fragmentRect.minY, height: fragmentRect.height))
        }
        return rows
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

    /// Draws ▸ (collapsed) or ▾ (expanded) centered in the marker column for a
    /// row. The triangle is a path rather than text so it stays crisp at every
    /// zoom level.
    private func drawMarker(_ marker: FoldMarkerState, atTopY topY: CGFloat,
                            height: CGFloat, textView: NSTextView) {
        let side = max(5, min(9, numberFont(for: textView).pointSize))
        let rowTop = bounds.height - topY - height
        let midY = rowTop + height / 2
        let centerX = Self.markerColumnWidth / 2

        let path = NSBezierPath()
        switch marker {
        case .collapsed: // ▸ pointing at the code
            let top = NSPoint(x: centerX - side * 0.3, y: midY + side / 2)
            let bottom = NSPoint(x: centerX - side * 0.3, y: midY - side / 2)
            let tip = NSPoint(x: centerX + side * 0.4, y: midY)
            path.move(to: top)
            path.line(to: bottom)
            path.line(to: tip)
        case .expanded: // ▾ pointing down at the hidden range
            let left = NSPoint(x: centerX - side / 2, y: midY + side * 0.3)
            let right = NSPoint(x: centerX + side / 2, y: midY + side * 0.3)
            let tip = NSPoint(x: centerX, y: midY - side * 0.4)
            path.move(to: left)
            path.line(to: right)
            path.line(to: tip)
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
    }

    /// Draws a filled circle in the bookmark margin for a bookmarked row.
    ///
    /// Notepad++ marks bookmarks with a blue dot; the circle is a path rather
    /// than a glyph so it stays crisp at every zoom level, matching the fold
    /// triangle above.
    private func drawBookmark(atTopY topY: CGFloat, height: CGFloat, textView: NSTextView) {
        let diameter = max(5, min(9, numberFont(for: textView).pointSize))
        let rowTop = bounds.height - topY - height
        let midY = rowTop + height / 2
        let centerX = Self.markerColumnWidth + Self.bookmarkColumnWidth / 2
        let rect = NSRect(x: centerX - diameter / 2,
                          y: midY - diameter / 2,
                          width: diameter,
                          height: diameter)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// Draws the unhide symbol for a hidden line range: three small dots in the
    /// trailing half of the marker column, leaving the fold triangle's centre
    /// free on lines that are also foldable. Clicking it unhides the range.
    private func drawHiddenRangeMarker(atTopY topY: CGFloat, height: CGFloat,
                                       textView: NSTextView) {
        let diameter = max(1.5, min(2.5, numberFont(for: textView).pointSize * 0.18))
        let rowTop = bounds.height - topY - height
        let midY = rowTop + height / 2
        let spacing = diameter + 1.5
        let lastX = Self.markerColumnWidth - diameter - 1
        NSColor.secondaryLabelColor.setFill()
        for step in 0..<3 {
            let x = lastX - CGFloat(2 - step) * spacing
            let rect = NSRect(x: x, y: midY - diameter / 2,
                              width: diameter, height: diameter)
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    // MARK: - Mouse

    /// Maps a mouse event into the character index it landed on, resolving it
    /// through the text layout. Our bounds are the same height as the clip view
    /// and we sit beside it; map the Y straight into text-view coordinates.
    private func characterIndex(for event: NSEvent) -> Int? {
        characterIndex(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    private func characterIndex(atViewPoint point: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let textY = bounds.height - point.y // we are non-flipped, text view is flipped
        var fraction: CGFloat = 0
        return layoutManager.characterIndex(for: NSPoint(x: 0, y: textY),
                                            in: container,
                                            fractionOfDistanceBetweenInsertionPoints: &fraction)
    }

    /// Consumes a press that lands on a drawn fold marker.
    ///
    /// - Returns: `true` when the press was a marker click and a fold toggle was
    ///   requested. `false` means the press belongs to the line-number column
    ///   (including the marker column on a line with no fold), preserving the
    ///   gutter's existing line-selection behavior.
    @discardableResult
    func handleFoldMarkerClick(at point: NSPoint, modifierFlags: NSEvent.ModifierFlags = []) -> Bool {
        guard point.x < Self.markerColumnWidth,
              let line = logicalLine(atViewPoint: point),
              markerState(forLine: line) != nil else { return false }
        dragAnchorCharIndex = nil
        if modifierFlags.contains(.shift) {
            onExpandFoldSubtree?(line)
        } else if modifierFlags.contains(.option) {
            onCollapseFoldSubtree?(line)
        } else {
            onToggleFold?(line)
        }
        return true
    }

    /// Consumes a press that lands on a hidden-range symbol.
    ///
    /// Hidden rows have no layout, so the symbol is drawn on the anchor line
    /// the container supplies; clicking it asks the editor to unhide that whole
    /// range.
    ///
    /// - Returns: `true` when the press was a hidden-range symbol click.
    @discardableResult
    func handleHiddenRangeClick(at point: NSPoint) -> Bool {
        guard point.x < Self.markerColumnWidth,
              let line = logicalLine(atViewPoint: point),
              let range = hiddenRangeMarkersProvider?()[line] else { return false }
        dragAnchorCharIndex = nil
        onUnhideHiddenRange?(range)
        return true
    }

    /// Consumes a press that lands in the bookmark margin.
    ///
    /// Every valid line has a bookmark margin (unlike the fold column, which
    /// only reacts where a fold starts), so the whole column toggles the line's
    /// bookmark like Notepad++'s bookmark margin.
    ///
    /// - Returns: `true` when the press was a bookmark-margin click.
    @discardableResult
    func handleBookmarkClick(at point: NSPoint) -> Bool {
        guard point.x >= Self.markerColumnWidth,
              point.x < Self.markerColumnWidth + Self.bookmarkColumnWidth,
              let line = logicalLine(atViewPoint: point) else { return false }
        dragAnchorCharIndex = nil
        onToggleBookmark?(line)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Unhide symbols share the leading column with fold markers; they are
        // checked first because they are drawn in its trailing half and are the
        // only way back for a hidden block with no fold of its own.
        if handleHiddenRangeClick(at: point) {
            return
        }
        // A press on a drawn fold marker toggles the fold and intentionally does
        // not start a line selection.
        if handleFoldMarkerClick(at: point, modifierFlags: event.modifierFlags) {
            return
        }
        // The bookmark margin toggles a bookmark on any line and likewise does
        // not start a line selection.
        if handleBookmarkClick(at: point) {
            return
        }

        guard let index = characterIndex(for: event) else { return }
        // A press starts a fresh selection anchored at the clicked line.
        dragAnchorCharIndex = index
        clickHandler?(index, index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = characterIndex(for: event) else { return }
        guard let dragAnchorCharIndex else { return }
        // Extend the selection from the anchor through the dragged line.
        clickHandler?(index, dragAnchorCharIndex)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorCharIndex = nil
        super.mouseUp(with: event)
    }

    /// 1-based logical line under a point in this view, resolved through text
    /// layout.
    private func logicalLine(atViewPoint point: NSPoint) -> Int? {
        guard let index = characterIndex(atViewPoint: point), let textView else { return nil }
        return GutterGeometry.logicalLine(of: index, in: textView.string)
    }
}
