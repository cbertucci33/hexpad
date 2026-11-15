import AppKit
import HexpadKit

/// One logical line in the minimap.
///
/// `type` is the line's dominant token type (`nil` for a blank line) and
/// `widthFraction` is the line's horizontal weight relative to
/// ``MinimapLineModel/referenceColumns``, capped at 1 so a long line simply
/// fills the minimap width.
struct MinimapLine: Equatable {
    let line: Int
    let type: TokenType?
    let widthFraction: CGFloat
}

/// Cached, per-logical-line colour model for the minimap.
///
/// Building the model tokenizes the whole buffer once. It is intentionally a
/// value type: the view compares a freshly built model with the cached one and
/// only asks for a redraw when the rows actually changed, so typing inside a
/// line whose dominant type and width do not change costs no repaint.
struct MinimapLineModel: Equatable {

    /// Columns that fill the minimap width. Longer lines are clamped to 1.
    static let referenceColumns = 100

    /// Above this length the minimap renders plain foreground rows instead of
    /// tokenizing the whole file. Mirrors ``TokenStore/largeFileThreshold`` so
    /// the minimap cannot become the one O(document) pass on huge files.
    static let maxTokenizedLength = 1_000_000

    let lines: [MinimapLine]
    let language: Language

    /// Computes the per-line colour model for `text`.
    ///
    /// Line boundaries use LF only, exactly like ``GutterGeometry``, so the
    /// minimap and the gutter always agree on line numbering (including the
    /// trailing empty line after a final newline).
    static func compute(text: String, language: Language) -> MinimapLineModel {
        let nsText = text as NSString
        let ranges = lineRanges(in: nsText)

        // Plain text has no syntax tokens, and huge files deliberately skip
        // tokenization. Both render one foreground-coloured row per line.
        if language == .plain || nsText.length > maxTokenizedLength {
            let lines = ranges.enumerated().map { index, range -> MinimapLine in
                let count = nonWhitespaceCount(in: range, text: nsText)
                return MinimapLine(line: index + 1,
                                   type: count > 0 ? .plain : nil,
                                   widthFraction: widthFraction(for: count))
            }
            return MinimapLineModel(lines: lines, language: language)
        }

        let tokens = SyntaxTokenizer.tokenize(text, language: language)
        var counts = Array(repeating: [TokenType: Int](), count: ranges.count)

        // Tokens are sorted and non-overlapping. `tokenIndex` only advances
        // past tokens that ended before the current line; a multi-line token
        // (block comment, multi-line string) keeps being counted on every line
        // it intersects.
        var tokenIndex = 0
        for (lineIndex, range) in ranges.enumerated() {
            let lineStart = range.location
            let lineEnd = NSMaxRange(range)

            while tokenIndex < tokens.count,
                  NSMaxRange(tokens[tokenIndex].range) <= lineStart {
                tokenIndex += 1
            }

            var scan = tokenIndex
            while scan < tokens.count, tokens[scan].range.location < lineEnd {
                let token = tokens[scan]
                let start = max(token.range.location, lineStart)
                let end = min(NSMaxRange(token.range), lineEnd)
                if end > start, token.type != .whitespace {
                    counts[lineIndex][token.type, default: 0] += end - start
                }
                scan += 1
            }
        }

        let lines = ranges.enumerated().map { index, range -> MinimapLine in
            let count = nonWhitespaceCount(in: range, text: nsText)
            return MinimapLine(line: index + 1,
                               type: dominantType(in: counts[index]),
                               widthFraction: widthFraction(for: count))
        }
        return MinimapLineModel(lines: lines, language: language)
    }

    /// The token type covering the most characters on a line.
    ///
    /// Whitespace is never dominant (it is not in the priority list). Ties use
    /// declaration order, so the result is deterministic rather than dependent
    /// on dictionary iteration order.
    static func dominantType(in counts: [TokenType: Int]) -> TokenType? {
        let priority: [TokenType] = [
            .keyword, .string, .comment, .number, .type,
            .function, .variable, .operator, .punctuation, .plain
        ]
        var best: TokenType?
        var bestCount = 0
        for type in priority {
            let count = counts[type] ?? 0
            if count > bestCount {
                best = type
                bestCount = count
            }
        }
        return best
    }

    // MARK: - Line math

    /// One range per logical line, excluding the LF terminator. Always at
    /// least one range so an empty document still has a single row.
    private static func lineRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        let length = text.length
        for index in 0..<length where text.character(at: index) == 10 {
            ranges.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        ranges.append(NSRange(location: start, length: length - start))
        return ranges
    }

    private static func nonWhitespaceCount(in range: NSRange, text: NSString) -> Int {
        guard range.length > 0 else { return 0 }
        var count = 0
        for index in range.location..<NSMaxRange(range) {
            switch text.character(at: index) {
            case 9, 11, 12, 13, 32: // tab, vertical tab, form feed, CR, space
                continue
            default:
                count += 1
            }
        }
        return count
    }

    private static func widthFraction(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return min(1, CGFloat(count) / CGFloat(referenceColumns))
    }
}

/// Pure minimap geometry. Kept separate from the view so the viewport overlay
/// and the click-to-scroll mapping are unit-testable without a window server.
enum MinimapGeometry {

    /// A viewport covering a tiny fraction of a very long document still needs
    /// to remain visible (and clickable) as a band.
    static let minimumViewportHeight: CGFloat = 4

    /// Height of one logical line's row when the whole document is fitted into
    /// `height`.
    static func rowHeight(lineCount: Int, height: CGFloat) -> CGFloat {
        guard lineCount > 0, height > 0 else { return 0 }
        return height / CGFloat(lineCount)
    }

    /// Normalised position of `y` inside the minimap, clamped to 0...1.
    static func fraction(atY y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(max(0, y / height), 1)
    }

    /// 0-based line index under a minimap Y position.
    static func lineIndex(atY y: CGFloat, lineCount: Int, height: CGFloat) -> Int {
        guard lineCount > 0 else { return 0 }
        let position = fraction(atY: y, height: height)
        return min(lineCount - 1, Int(position * CGFloat(lineCount)))
    }

    /// Character index of the first character of the line under `y`.
    /// Reuses ``GutterGeometry`` so minimap clicks and gutter clicks resolve
    /// lines through the same implementation.
    static func characterIndex(atY y: CGFloat,
                               text: String,
                               lineCount: Int,
                               height: CGFloat) -> Int {
        let line = lineIndex(atY: y, lineCount: lineCount, height: height) + 1
        return GutterGeometry.firstCharIndex(of: line, in: text)
    }

    /// Overlay rectangle for the lines covered by `visibleCharacterRange`.
    ///
    /// Uses logical line numbers (not laid-out pixel heights) so the overlay
    /// and the per-line rows share one coordinate system, including when lines
    /// wrap or folded content changes the layout height.
    static func viewportRect(visibleCharacterRange: NSRange,
                             text: String,
                             lineCount: Int,
                             width: CGFloat,
                             height: CGFloat) -> NSRect? {
        guard lineCount > 0, height > 0 else { return nil }

        let textLength = (text as NSString).length
        let hasVisibleText = visibleCharacterRange.length > 0 && textLength > 0
        let firstChar = hasVisibleText
            ? min(max(0, visibleCharacterRange.location), textLength - 1)
            : 0
        let lastChar = hasVisibleText
            ? min(max(firstChar, NSMaxRange(visibleCharacterRange) - 1), textLength - 1)
            : 0

        let firstLine = GutterGeometry.logicalLine(of: firstChar, in: text)
        let lastLine = hasVisibleText
            ? GutterGeometry.logicalLine(of: lastChar, in: text)
            : firstLine

        let rowHeight = self.rowHeight(lineCount: lineCount, height: height)
        let rawHeight = CGFloat(max(1, lastLine - firstLine + 1)) * rowHeight
        let overlayHeight = min(height, max(rawHeight, minimumViewportHeight))
        let rawY = CGFloat(max(0, firstLine - 1)) * rowHeight
        let y = min(max(0, rawY), max(0, height - overlayHeight))
        return NSRect(x: 0, y: y, width: width, height: overlayHeight)
    }

    /// Scroll origin that centres `fraction` of the document in the viewport.
    ///
    /// Centring (rather than top-aligning) makes a minimap drag stable: the
    /// clicked spot stays under the cursor as the overlay follows it.
    static func scrollOriginY(fraction: CGFloat,
                              documentHeight: CGFloat,
                              viewportHeight: CGFloat) -> CGFloat {
        let maxOrigin = max(0, documentHeight - viewportHeight)
        let centered = min(max(0, fraction), 1) * documentHeight - viewportHeight / 2
        return min(max(0, centered), maxOrigin)
    }
}

/// Scaled-down document overview rendered to the right of the editor.
///
/// Rendering model:
/// - One row per logical line, coloured by ``MinimapLineModel``.
/// - A viewport rectangle (and a caret line) is drawn from live text layout.
/// - Clicking or dragging scrolls the editor, centring the clicked document
///   position.
///
/// Invalidation is deliberately narrow: text changes mark the cached model
/// dirty and rebuild it on the next run-loop turn (comparing before redrawing);
/// scroll, resize, and selection changes only repaint the union of the old and
/// new overlay rectangles, never the whole minimap.
final class MinimapView: NSView {

    /// Fixed width in points.
    static let width: CGFloat = 100

    /// Left/right padding for line rows.
    static let horizontalInset: CGFloat = 6

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private weak var document: DocumentModel?

    /// Cached line-colour model. Tests and diagnostics can inspect it.
    private(set) var lineModel: MinimapLineModel?

    /// True between a text-change notification and the coalesced rebuild.
    private(set) var modelNeedsRebuild = false

    /// Current palette. Assigning a different theme asks for a full redraw.
    var theme: Theme {
        didSet { needsDisplay = true }
    }

    /// Set once the window controller supplies an explicit theme, so a system
    /// appearance change does not replace a user-selected Light/Dark override.
    private var hasExplicitTheme = false

    private var storageObserver: NSObjectProtocol?
    private var documentObserver: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var pendingRebuild: DispatchWorkItem?

    private var lastViewportRect = NSRect.zero
    private var lastCaretRect = NSRect.zero

    /// The minimap draws top-down like the text view, so Y values and line
    /// order share one direction.
    override var isFlipped: Bool { true }

    init(textView: NSTextView? = nil, scrollView: NSScrollView? = nil) {
        self.textView = textView
        self.scrollView = scrollView
        self.theme = HexpadTheme.forAppearance(NSAppearance.currentDrawing())
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        isHidden = true
        startObservingLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        if let documentObserver {
            NotificationCenter.default.removeObserver(documentObserver)
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pendingRebuild?.cancel()
    }

    // MARK: - Binding

    /// Points the minimap at a document. Passing `nil` hides the view, which is
    /// also how the editor container avoids reserving width for an empty tab.
    func bind(to document: DocumentModel?) {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
            self.storageObserver = nil
        }
        if let documentObserver {
            NotificationCenter.default.removeObserver(documentObserver)
            self.documentObserver = nil
        }

        self.document = document
        guard let document else {
            isHidden = true
            rebuildModelNow()
            return
        }

        isHidden = false
        let center = NotificationCenter.default
        storageObserver = center.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: document.textStorage,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.storageDidEdit(notification)
        }
        documentObserver = center.addObserver(
            forName: DocumentModel.textDidChangeNotification,
            object: document,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.scheduleModelRebuild()
        }

        // Binding happens on tab switches and language changes; both can alter
        // the dominant token type, so rebuild eagerly for the first paint.
        rebuildModelNow()
    }

    /// Applies the editor's current theme. Repeated calls with the same theme
    /// (the controller calls this on every keystroke) are no-ops, so they
    /// cannot force a per-keystroke redraw.
    func apply(theme: Theme) {
        hasExplicitTheme = true
        guard theme.name != self.theme.name || theme.background != self.theme.background else {
            return
        }
        self.theme = theme
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !hasExplicitTheme else { return }
        theme = HexpadTheme.forAppearance(effectiveAppearance)
    }

    // MARK: - Model cache

    /// Rebuilds the cached model immediately. The editor container's initial
    /// bind and tests use this; ordinary text edits go through the coalesced
    /// ``scheduleModelRebuild()`` path.
    func rebuildModelNow() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        modelNeedsRebuild = false

        guard let document else {
            if lineModel != nil {
                lineModel = nil
                needsDisplay = true
            }
            return
        }

        let language = Language(rawValue: document.language) ?? .plain
        let model = MinimapLineModel.compute(text: document.text, language: language)
        // Equality is the "visible change" test: if the rows are identical the
        // cached model is already correct and no repaint is needed.
        guard model != lineModel else { return }
        lineModel = model
        needsDisplay = true
    }

    /// Coalesces a burst of keystrokes into one model rebuild on the next
    /// run-loop turn. Attribute-only edits never reach this path.
    private func scheduleModelRebuild() {
        modelNeedsRebuild = true
        guard pendingRebuild == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildModelNow()
        }
        pendingRebuild = work
        DispatchQueue.main.async(execute: work)
    }

    private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage === document?.textStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        scheduleModelRebuild()
    }

    // MARK: - Live layout observation

    private func startObservingLayout() {
        guard let textView, let scrollView else { return }
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true

        let overlay: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.invalidateOverlay()
        }
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                           object: clip, queue: .main, using: overlay))
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                           object: clip, queue: .main, using: overlay))
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                           object: textView, queue: .main, using: overlay))
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                           object: textView, queue: .main, using: overlay))
        observers.append(center.addObserver(
            forName: NSNotification.Name("NSLayoutManagerDidInvalidateLayoutNotification"),
            object: textView.layoutManager,
            queue: .main,
            using: overlay
        ))
    }

    /// Repaints only the union of the old/new viewport and caret bands.
    private func invalidateOverlay() {
        let viewport = viewportRect() ?? .zero
        let caret = caretRect() ?? .zero
        let dirty = viewport.union(lastViewportRect).union(caret).union(lastCaretRect)
        lastViewportRect = viewport
        lastCaretRect = caret
        setNeedsDisplay(dirty.insetBy(dx: -1, dy: -1))
    }

    private func visibleCharacterRange() -> NSRange {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        let length = (textView.string as NSString).length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect,
                                                  in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        guard charRange.length > 0 else {
            // TextKit has not laid the view out yet; start at the top.
            return NSRange(location: 0, length: min(length, 4_000))
        }
        return charRange
    }

    private var lineCount: Int {
        if let lineModel { return lineModel.lines.count }
        guard let textView else { return 0 }
        return GutterGeometry.lineCount(in: textView.string)
    }

    private func viewportRect() -> NSRect? {
        guard let textView, bounds.width > 0, bounds.height > 0 else { return nil }
        return MinimapGeometry.viewportRect(
            visibleCharacterRange: visibleCharacterRange(),
            text: textView.string,
            lineCount: lineCount,
            width: bounds.width,
            height: bounds.height
        )
    }

    /// One-row band for the primary caret's logical line.
    private func caretRect() -> NSRect? {
        guard let textView, lineCount > 0, bounds.height > 0 else { return nil }
        let text = textView.string
        let location = min(max(0, textView.selectedRange().location),
                           (text as NSString).length)
        let line = GutterGeometry.logicalLine(of: location, in: text)
        let rowHeight = MinimapGeometry.rowHeight(lineCount: lineCount,
                                                  height: bounds.height)
        let height = max(1.5, rowHeight)
        let y = min(max(0, CGFloat(line - 1) * rowHeight),
                    max(0, bounds.height - height))
        return NSRect(x: 0, y: y, width: bounds.width, height: height)
    }

    // MARK: - Drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        invalidateOverlay()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isHidden, bounds.width > 0, bounds.height > 0 else { return }

        // Only the dirty band is cleared; scroll repaints therefore cannot
        // erase rows outside their overlay union.
        let background = theme.background.blended(withFraction: 0.08, of: .black)
            ?? theme.background
        background.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        if let model = lineModel, !model.lines.isEmpty {
            drawLines(model, in: dirtyRect)
        }
        drawOverlay(in: dirtyRect)
    }

    private func drawLines(_ model: MinimapLineModel, in dirtyRect: NSRect) {
        let rowHeight = MinimapGeometry.rowHeight(lineCount: model.lines.count,
                                                  height: bounds.height)
        guard rowHeight > 0 else { return }
        let drawHeight = max(1, rowHeight)
        let usableWidth = max(0, bounds.width - Self.horizontalInset * 2)

        // Rows outside the dirty band are skipped, which keeps a one-row
        // overlay repaint O(visible rows) even for very large documents.
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)) - 1)
        let last = min(model.lines.count,
                       Int(ceil(dirtyRect.maxY / rowHeight)) + 1)
        guard first < last else { return }

        for index in first..<last {
            let line = model.lines[index]
            guard let type = line.type, line.widthFraction > 0 else { continue }
            let y = CGFloat(index) * rowHeight
            let rect = NSRect(x: Self.horizontalInset,
                              y: y,
                              width: max(1, usableWidth * line.widthFraction),
                              height: drawHeight)
            SyntaxTokenizer.color(for: type, theme: theme)
                .withAlphaComponent(0.82)
                .setFill()
            rect.fill()
        }
    }

    private func drawOverlay(in dirtyRect: NSRect) {
        let viewport = viewportRect() ?? .zero
        if !viewport.isEmpty {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).setFill()
            viewport.fill()

            let border = NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55).setStroke()
            border.stroke()
        }

        if let caret = caretRect() {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.75).setFill()
            NSRect(x: 0, y: caret.minY, width: 2, height: caret.height).fill()
        }

        lastViewportRect = viewport
        lastCaretRect = caretRect() ?? .zero
    }

    // MARK: - Click / drag scrolling

    override func mouseDown(with event: NSEvent) {
        scroll(toMinimapY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(toMinimapY: convert(event.locationInWindow, from: nil).y)
    }

    /// Scrolls the editor so the document position under the minimap Y is
    /// centred in the viewport. Exposed for wiring tests.
    func scroll(toMinimapY y: CGFloat) {
        guard let textView,
              let scrollView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              lineCount > 0 else { return }

        let clip = scrollView.contentView
        let laidOutHeight = layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2
        let documentHeight = max(laidOutHeight, clip.bounds.height)
        let targetY = MinimapGeometry.scrollOriginY(
            fraction: MinimapGeometry.fraction(atY: y, height: bounds.height),
            documentHeight: documentHeight,
            viewportHeight: clip.bounds.height
        )

        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clip)
    }
}
