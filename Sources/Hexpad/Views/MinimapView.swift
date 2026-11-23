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

    /// Content range of each logical line, parallel to `lines` and excluding
    /// the LF terminator. Cached so an edit can map one character offset to a
    /// line without rescanning the document from the start.
    let lineRanges: [NSRange]

    /// UTF-16 length of the text this model describes.
    let textLength: Int

    /// Computes the per-line colour model for `text`.
    ///
    /// Line boundaries use LF only, exactly like ``GutterGeometry``, so the
    /// minimap and the gutter always agree on line numbering (including the
    /// trailing empty line after a final newline).
    static func compute(text: String, language: Language) -> MinimapLineModel {
        let nsText = text as NSString
        let ranges = lineRanges(in: nsText)
        let lines = rows(text: text,
                         nsText: nsText,
                         language: language,
                         ranges: ranges,
                         firstLineNumber: 1)
        return MinimapLineModel(lines: lines,
                                language: language,
                                lineRanges: ranges,
                                textLength: nsText.length)
    }

    /// Recomputes only the line-aligned `band` touched by an edit and keeps
    /// the cached rows outside it.
    ///
    /// `band` is expressed in the post-edit text and must start/end on line
    /// boundaries (``MinimapView`` expands every edit with
    /// `TokenStore.lineRange`). Everything before the band is unchanged, and
    /// everything after it only shifts by the edit's delta, so the surrounding
    /// rows and their token types stay valid.
    static func updated(_ cached: MinimapLineModel,
                        text newText: String,
                        language: Language,
                        band: NSRange) -> MinimapLineModel {
        guard cached.language == language else {
            return compute(text: newText, language: language)
        }

        let nsText = newText as NSString
        let newLength = nsText.length
        let oldLineCount = cached.lines.count
        guard oldLineCount > 0, !cached.lineRanges.isEmpty,
              cached.lineRanges.count == oldLineCount else {
            return compute(text: newText, language: language)
        }

        let bandStart = min(max(0, band.location), newLength)
        let bandEnd = min(max(bandStart, NSMaxRange(band)), newLength)
        let oldStartLine = min(lineIndex(startingAtOrAfter: bandStart,
                                         in: cached.lineRanges),
                               oldLineCount - 1)

        // The suffix after the band is unchanged; map its start back into the
        // cached text so the rows to replace are known without keeping a copy
        // of the old document.
        let delta = newLength - cached.textLength
        let oldEndLocation = max(0, bandEnd - delta)
        let oldEndLine: Int
        if oldEndLocation >= cached.textLength {
            oldEndLine = oldLineCount - 1
        } else {
            oldEndLine = max(oldStartLine - 1,
                             lineIndex(startingAtOrAfter: oldEndLocation,
                                       in: cached.lineRanges) - 1)
        }

        let freshRanges = lineRanges(in: nsText, from: bandStart, to: bandEnd)
        let freshLines = rows(text: newText,
                              nsText: nsText,
                              language: language,
                              ranges: freshRanges,
                              firstLineNumber: oldStartLine + 1)

        let tailStart = min(max(oldStartLine, oldEndLine + 1), oldLineCount)
        let dropped = tailStart - oldStartLine
        let lineShift = freshLines.count - dropped

        var lines = Array(cached.lines[0..<oldStartLine])
        lines.append(contentsOf: freshLines)
        lines.append(contentsOf: cached.lines[tailStart...].map {
            MinimapLine(line: $0.line + lineShift,
                        type: $0.type,
                        widthFraction: $0.widthFraction)
        })

        var ranges = Array(cached.lineRanges[0..<oldStartLine])
        ranges.append(contentsOf: freshRanges)
        ranges.append(contentsOf: cached.lineRanges[tailStart...].map {
            NSRange(location: $0.location + delta, length: $0.length)
        })

        return MinimapLineModel(lines: lines,
                                language: language,
                                lineRanges: ranges,
                                textLength: newLength)
    }

    /// Per-line rows for `ranges`. Tokenizes only from the first line's start
    /// to the last line's end, so an incremental band never pays for a whole
    /// document pass.
    private static func rows(text: String,
                             nsText: NSString,
                             language: Language,
                             ranges: [NSRange],
                             firstLineNumber: Int) -> [MinimapLine] {
        guard let first = ranges.first, let last = ranges.last else { return [] }

        // Plain text has no syntax tokens, and huge files deliberately skip
        // tokenization. Both render one foreground-coloured row per line.
        if language == .plain || nsText.length > maxTokenizedLength {
            return ranges.enumerated().map { index, range -> MinimapLine in
                let count = nonWhitespaceCount(in: range, text: nsText)
                return MinimapLine(line: firstLineNumber + index,
                                   type: count > 0 ? .plain : nil,
                                   widthFraction: widthFraction(for: count))
            }
        }

        let tokenRange = NSRange(location: first.location,
                                 length: NSMaxRange(last) - first.location)
        let tokens = SyntaxTokenizer.tokenize(text, language: language, in: tokenRange)
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

        return ranges.enumerated().map { index, range -> MinimapLine in
            let count = nonWhitespaceCount(in: range, text: nsText)
            return MinimapLine(line: firstLineNumber + index,
                               type: dominantType(in: counts[index]),
                               widthFraction: widthFraction(for: count))
        }
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

    /// Line ranges for a line-aligned `[start, end)` band. Unlike the
    /// whole-document version this only walks the band's characters; the
    /// caller guarantees both endpoints sit on line boundaries (end may equal
    /// the document length).
    private static func lineRanges(in text: NSString,
                                   from start: Int,
                                   to end: Int) -> [NSRange] {
        guard start >= 0, end >= start,
              start <= text.length, end <= text.length else { return [] }

        var ranges: [NSRange] = []
        var lineStart = start
        var index = start
        while index < end {
            if text.character(at: index) == 10 {
                ranges.append(NSRange(location: lineStart, length: index - lineStart))
                lineStart = index + 1
            }
            index += 1
        }

        if lineStart < end {
            ranges.append(NSRange(location: lineStart, length: end - lineStart))
        } else if lineStart == end, end == text.length,
                  start == end || text.character(at: end - 1) == 10 {
            // The band ends with a line break at the end of the document, so
            // the trailing empty line belongs to it.
            ranges.append(NSRange(location: end, length: 0))
        }

        if ranges.isEmpty {
            // A zero-length band (empty document, or an insert at EOF) still
            // needs one row.
            ranges.append(NSRange(location: min(start, text.length), length: 0))
        }
        return ranges
    }

    /// Index of the first cached line whose start is at or after `location`.
    /// Used to map a line-aligned offset to its line without scanning text.
    private static func lineIndex(startingAtOrAfter location: Int,
                                  in ranges: [NSRange]) -> Int {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].location < location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
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

    /// Rows never grow past this height.
    ///
    /// Fitting the document into the strip is only meaningful while a row is a
    /// thin sliver. A handful of lines fitted into a tall editor would each
    /// become a huge bar that reads as a rendering defect, so a short document
    /// uses the top of the strip and leaves the rest as background.
    static let maximumRowHeight: CGFloat = 3

    /// Height at which the view actually paints a row: the fitted
    /// ``rowHeight(lineCount:height:)`` clamped to ``maximumRowHeight``.
    static func drawnRowHeight(lineCount: Int, height: CGFloat) -> CGFloat {
        min(rowHeight(lineCount: lineCount, height: height), maximumRowHeight)
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
    ///
    /// `rowHeightOverride` lets the view pass the capped row height it paints
    /// with, so the band always lines up with the rows actually drawn.
    ///
    /// This convenience overload builds one line index from `text`. The live
    /// view uses the `lineRanges` overload with its cached minimap model so a
    /// scroll/caret frame never scans the document.
    static func viewportRect(visibleCharacterRange: NSRange,
                             text: String,
                             lineCount: Int,
                             width: CGFloat,
                             height: CGFloat,
                             rowHeightOverride: CGFloat? = nil) -> NSRect? {
        let index = LineIndex(text)
        return viewportRect(visibleCharacterRange: visibleCharacterRange,
                            lineRanges: lineRanges(from: index),
                            textLength: index.textLength,
                            lineCount: lineCount,
                            width: width,
                            height: height,
                            rowHeightOverride: rowHeightOverride)
    }

    /// Overlay rectangle resolved against cached line ranges.
    ///
    /// `lineRanges` and `textLength` come from ``MinimapLineModel``; line
    /// numbers are found by binary search, so this is O(log lines) per call
    /// instead of the O(document) scan ``GutterGeometry/logicalLine(of:in:)``
    /// performs.
    static func viewportRect(visibleCharacterRange: NSRange,
                             lineRanges: [NSRange],
                             textLength: Int,
                             lineCount: Int,
                             width: CGFloat,
                             height: CGFloat,
                             rowHeightOverride: CGFloat? = nil) -> NSRect? {
        guard lineCount > 0, height > 0 else { return nil }

        let hasVisibleText = visibleCharacterRange.length > 0 && textLength > 0
        let firstChar = hasVisibleText
            ? min(max(0, visibleCharacterRange.location), textLength - 1)
            : 0
        let lastChar = hasVisibleText
            ? min(max(firstChar, NSMaxRange(visibleCharacterRange) - 1), textLength - 1)
            : 0

        let firstLine = logicalLine(of: firstChar,
                                    lineRanges: lineRanges,
                                    textLength: textLength)
        let lastLine = hasVisibleText
            ? logicalLine(of: lastChar, lineRanges: lineRanges, textLength: textLength)
            : firstLine

        let rowHeight = rowHeightOverride
            ?? self.rowHeight(lineCount: lineCount, height: height)
        let rawHeight = CGFloat(max(1, lastLine - firstLine + 1)) * rowHeight
        let overlayHeight = min(height, max(rawHeight, minimumViewportHeight))
        let rawY = CGFloat(max(0, firstLine - 1)) * rowHeight
        let y = min(max(0, rawY), max(0, height - overlayHeight))
        return NSRect(x: 0, y: y, width: width, height: overlayHeight)
    }

    /// 1-based logical line containing `charIndex`, using cached line ranges.
    ///
    /// `lineRanges` holds one content range per line, excluding the LF
    /// terminator (the same representation ``MinimapLineModel`` caches). The
    /// last range starting at or before the offset is that offset's line,
    /// which reproduces `GutterGeometry.logicalLine` exactly:
    ///
    /// - a caret on an LF still belongs to the line the LF terminates;
    /// - a caret one past the LF belongs to the next line;
    /// - positions past the end clamp to the final line.
    static func logicalLine(of charIndex: Int,
                            lineRanges: [NSRange],
                            textLength: Int) -> Int {
        guard !lineRanges.isEmpty, charIndex > 0 else { return 1 }
        let offset = min(charIndex, textLength)
        var low = 0
        var high = lineRanges.count
        while low < high {
            let mid = (low + high) / 2
            if lineRanges[mid].location <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(1, low)
    }

    /// Content ranges for every logical line, derived from a full index.
    /// Mirrors ``MinimapLineModel``'s ranges (LF excluded).
    private static func lineRanges(from index: LineIndex) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges.reserveCapacity(index.lineStarts.count)
        for (line, start) in index.lineStarts.enumerated() {
            let end = line + 1 < index.lineStarts.count
                ? index.lineStarts[line + 1] - 1
                : index.textLength
            ranges.append(NSRange(location: start, length: max(0, end - start)))
        }
        return ranges
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

    /// Cached line-colour model, or `nil` before the first build.
    private var cachedLineModel: MinimapLineModel?

    /// Cached line-colour model. Tests and diagnostics can inspect it.
    ///
    /// Reading this while the map is hidden builds the model on demand
    /// (tests do this); normal production reads happen only from ``draw``,
    /// which is gated on visibility, so a hidden map costs nothing.
    var lineModel: MinimapLineModel? {
        ensureModelBuilt()
        return cachedLineModel
    }

    /// Test/diagnostic hook: whether a model has been built for the bound
    /// document. A hidden map leaves this `false` until shown or inspected.
    var hasBuiltLineModel: Bool { cachedLineModel != nil }

    /// True between a text-change notification and the coalesced rebuild.
    private(set) var modelNeedsRebuild = false

    /// Test/diagnostic hook: whole-buffer line scans performed by overlay
    /// geometry. With a bound model the viewport/caret rectangles are resolved
    /// from the cached line ranges by binary search, so scroll, resize and
    /// caret frames must leave this unchanged. It only grows before a model is
    /// available (or for an unbound buffer).
    private(set) var overlayFullTextScanCount = 0

    /// Line-aligned band in the current text that the next rebuild must
    /// recompute. `nil` asks for a full rebuild, which is reserved for bind and
    /// language changes; ordinary edits merge into this band.
    private var pendingEditBand: NSRange?

    /// Current palette. Assigning a different theme asks for a full redraw.
    var theme: Theme {
        didSet { needsDisplay = true }
    }

    /// Whether the document map preference is on. The view still stays hidden
    /// while no document is bound, so an empty pane never shows an empty rail.
    ///
    /// The model is only maintained while the map is visible (or has been
    /// inspected). Showing it builds once, folding in any edits recorded since
    /// it was last visible; hiding it cancels pending work.
    var isDocumentMapVisible = false {
        didSet {
            updateVisibility()
            if isDocumentMapVisible {
                let needsFullBuild = cachedLineModel == nil
                if needsFullBuild || modelNeedsRebuild {
                    rebuildModelNow(full: needsFullBuild)
                }
                needsDisplay = true
            } else {
                pendingRebuild?.cancel()
                pendingRebuild = nil
                lastViewportRect = .zero
                lastCaretRect = .zero
                overlayRectsAreCurrent = false
            }
        }
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

    /// Set while ``lastViewportRect``/``lastCaretRect`` describe the current
    /// scroll position and text. ``invalidateOverlay`` refreshes them once per
    /// event; the following draw reuses them instead of recomputing. Any model
    /// change (line count or offsets) clears the flag so draw recomputes.
    private var overlayRectsAreCurrent = false

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

    /// Single place that decides visibility: the preference is on and a
    /// document is bound. Unbinding therefore hides without touching the
    /// preference, and turning the preference off does not forget the document.
    private func updateVisibility() {
        isHidden = !isDocumentMapVisible || document == nil
    }

    // MARK: - Binding

    /// Same-document identity plus the model's current language and staleness.
    /// `modelNeedsRebuild`/`pendingEditBand` mean an observed edit has not yet
    /// been folded into the cache, so skipping would lose it.
    private func isBoundTo(_ document: DocumentModel?) -> Bool {
        guard let current = self.document, let document else {
            return self.document == nil && document == nil
        }
        guard current === document else { return false }
        guard !modelNeedsRebuild, pendingEditBand == nil else { return false }
        let language = Language(rawValue: document.language) ?? .plain
        // With no cached model (the normal hidden state) there is nothing to
        // invalidate; a later build reads the document's language directly.
        guard let cachedLineModel else { return true }
        return cachedLineModel.language == language
    }

    /// Points the minimap at a document. Passing `nil` hides the view, which is
    /// also how the editor container avoids reserving width for an empty tab.
    /// A bound document only appears when the document map preference is on.
    ///
    /// Re-binding the same document is skipped unless its language changed or
    /// an edit is still waiting to be folded into the cached model; the model
    /// observes that buffer incrementally, so a full rebuild would be pure
    /// duplicate work.
    func bind(to document: DocumentModel?, force: Bool = false) {
        if !force, isBoundTo(document) { return }
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
            updateVisibility()
            pendingEditBand = nil
            pendingRebuild?.cancel()
            pendingRebuild = nil
            modelNeedsRebuild = false
            if cachedLineModel != nil {
                cachedLineModel = nil
                overlayRectsAreCurrent = false
                needsDisplay = true
            }
            return
        }

        updateVisibility()
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
        // the dominant token type. A visible map rebuilds eagerly for the first
        // paint. A hidden map only marks itself dirty: the build is deferred
        // until it is shown (and a stale model from the previous tab is dropped
        // so it can never be drawn).
        pendingEditBand = nil
        if isDocumentMapVisible {
            rebuildModelNow(full: true)
        } else {
            pendingRebuild?.cancel()
            pendingRebuild = nil
            cachedLineModel = nil
            overlayRectsAreCurrent = false
            modelNeedsRebuild = true
        }
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
    /// ``scheduleModelRebuild()`` path and update only the edited line band.
    func rebuildModelNow() {
        rebuildModelNow(full: false)
    }

    /// Builds the model if it has never been built. This is the lazy path used
    /// by diagnostics (and tests) so a hidden map can still be inspected
    /// without paying for a model at bind time.
    private func ensureModelBuilt() {
        guard cachedLineModel == nil, document != nil else { return }
        rebuildModelNow(full: true)
    }

    private func rebuildModelNow(full: Bool) {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        modelNeedsRebuild = false

        guard let document else {
            pendingEditBand = nil
            if cachedLineModel != nil {
                cachedLineModel = nil
                overlayRectsAreCurrent = false
                needsDisplay = true
            }
            return
        }

        let language = Language(rawValue: document.language) ?? .plain
        let text = document.text
        let band = pendingEditBand
        pendingEditBand = nil

        let model: MinimapLineModel
        if !full, let band, let cached = cachedLineModel, cached.language == language {
            // Only the rows intersecting the edited band are re-tokenized; the
            // rest of the cached model is preserved (with later rows shifted
            // when the edit added or removed lines).
            model = MinimapLineModel.updated(cached,
                                             text: text,
                                             language: language,
                                             band: band)
        } else {
            model = MinimapLineModel.compute(text: text, language: language)
        }

        // Equality is the "visible change" test: if the rows are identical the
        // cached model is already correct and no repaint is needed.
        guard model != cachedLineModel else { return }
        cachedLineModel = model
        overlayRectsAreCurrent = false
        needsDisplay = true
    }

    /// Coalesces a burst of keystrokes into one model rebuild on the next
    /// run-loop turn. Attribute-only edits never reach this path.
    ///
    /// While the map is hidden this only records that the model is stale; the
    /// band merge, array copies and model comparison are deferred until the
    /// map is shown.
    private func scheduleModelRebuild() {
        modelNeedsRebuild = true
        guard isDocumentMapVisible else {
            pendingRebuild?.cancel()
            pendingRebuild = nil
            return
        }
        guard pendingRebuild == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRebuild = nil
            guard self.isDocumentMapVisible else { return }
            self.rebuildModelNow()
        }
        pendingRebuild = work
        DispatchQueue.main.async(execute: work)
    }

    private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage === document?.textStorage,
              storage.editedMask.contains(.editedCharacters) else { return }

        // A hidden map with no built model has nothing to keep in step: record
        // only staleness and defer the line-band mapping until it is shown.
        // (A model built by a diagnostic while hidden is still updated so the
        // next inspection is incremental, matching the old behaviour.)
        guard isDocumentMapVisible || cachedLineModel != nil else {
            pendingEditBand = nil
            scheduleModelRebuild()
            return
        }

        let editedRange = storage.editedRange
        let insertedLength = editedRange.length
        let replacedLength = max(0, insertedLength - storage.changeInLength)
        recordEdit(location: editedRange.location,
                   replacedLength: replacedLength,
                   insertedLength: insertedLength)
        scheduleModelRebuild()
    }

    /// Merges an edit into the pending band in post-edit coordinates.
    ///
    /// The band is kept line-aligned with one line of context on each side so
    /// a line join/split and a token on the band boundary are recomputed too.
    /// Earlier edits are shifted when a later one lands before them, which is
    /// exactly the order multi-caret replacements arrive in.
    private func recordEdit(location: Int,
                            replacedLength: Int,
                            insertedLength: Int) {
        guard let document else {
            pendingEditBand = nil
            return
        }

        let text = document.text as NSString
        let editEnd = location + insertedLength
        let oldEditEnd = location + replacedLength
        let delta = insertedLength - replacedLength

        let merged: NSRange
        if let existing = pendingEditBand {
            var start = existing.location
            var end = NSMaxRange(existing)
            if end <= location {
                // The earlier band is entirely before this edit.
            } else if start >= oldEditEnd {
                // The earlier band is entirely after this edit and shifts.
                start += delta
                end += delta
            } else {
                // Overlap: map the earlier band's endpoints across the edit.
                let mappedStart = start <= location ? start : location
                let mappedEnd = end >= oldEditEnd ? end + delta : editEnd
                start = mappedStart
                end = mappedEnd
            }
            start = min(start, location)
            end = max(end, editEnd)
            merged = NSRange(location: start, length: max(0, end - start))
        } else {
            merged = NSRange(location: location, length: insertedLength)
        }

        pendingEditBand = TokenStore.lineRange(containing: merged,
                                               in: text,
                                               margin: 1)
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
        // A hidden map has no overlay to keep current; skip the line math
        // entirely. Showing it resets the cached rects and repaints once.
        guard !isHidden else { return }
        let viewport = viewportRect() ?? .zero
        let caret = caretRect() ?? .zero
        let dirty = viewport.union(lastViewportRect).union(caret).union(lastCaretRect)
        lastViewportRect = viewport
        lastCaretRect = caret
        overlayRectsAreCurrent = true
        setNeedsDisplay(dirty.insetBy(dx: -1, dy: -1))
    }

    private func visibleCharacterRange() -> NSRange {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        let length = textView.textStorage?.length ?? 0
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
        if let cachedLineModel { return cachedLineModel.lines.count }
        guard let textView else { return 0 }
        overlayFullTextScanCount += 1
        return GutterGeometry.lineCount(in: textView.string)
    }

    /// Height this view paints one row at. See
    /// ``MinimapGeometry/drawnRowHeight(lineCount:height:)``: rows are capped so
    /// a short document does not stretch into a few giant bars.
    private var paintedRowHeight: CGFloat {
        MinimapGeometry.drawnRowHeight(lineCount: lineCount, height: bounds.height)
    }

    private func viewportRect() -> NSRect? {
        guard let textView, bounds.width > 0, bounds.height > 0 else { return nil }
        let visible = visibleCharacterRange()

        // The bound model already carries one range per logical line, so the
        // overlay resolves its line numbers by binary search. No scroll,
        // resize or caret frame reads the document text.
        if let model = cachedLineModel {
            return MinimapGeometry.viewportRect(
                visibleCharacterRange: visible,
                lineRanges: model.lineRanges,
                textLength: model.textLength,
                lineCount: model.lines.count,
                width: bounds.width,
                height: bounds.height,
                rowHeightOverride: paintedRowHeight
            )
        }

        overlayFullTextScanCount += 1
        let text = textView.string
        return MinimapGeometry.viewportRect(
            visibleCharacterRange: visible,
            text: text,
            lineCount: GutterGeometry.lineCount(in: text),
            width: bounds.width,
            height: bounds.height,
            rowHeightOverride: paintedRowHeight
        )
    }

    /// One-row band for the primary caret's logical line.
    private func caretRect() -> NSRect? {
        guard let textView, lineCount > 0, bounds.height > 0 else { return nil }
        let location = max(0, textView.selectedRange().location)
        let line: Int
        if let model = cachedLineModel {
            line = MinimapGeometry.logicalLine(of: location,
                                               lineRanges: model.lineRanges,
                                               textLength: model.textLength)
        } else {
            overlayFullTextScanCount += 1
            line = GutterGeometry.logicalLine(of: location, in: textView.string)
        }
        let rowHeight = paintedRowHeight
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

        // AppKit forwards a whole-window invalidation to every subview without
        // intersecting it with the subview's frame, so `dirtyRect` can reach far
        // outside these bounds. This view fills its dirty band opaquely and is
        // the last sibling in the container, so painting the raw rect used to
        // erase the gutter and the text view on every full repaint. Never draw
        // outside our own bounds.
        let dirty = dirtyRect.intersection(bounds)
        guard !dirty.isEmpty else { return }

        // Only the dirty band is cleared; scroll repaints therefore cannot
        // erase rows outside their overlay union.
        let background = theme.background.blended(withFraction: 0.08, of: .black)
            ?? theme.background
        background.setFill()
        dirty.fill()

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: dirty.minY, width: 1, height: dirty.height).fill()

        if let model = cachedLineModel, !model.lines.isEmpty {
            drawLines(model, in: dirty)
        }
        drawOverlay(in: dirty)
    }

    private func drawLines(_ model: MinimapLineModel, in dirtyRect: NSRect) {
        let rowHeight = paintedRowHeight
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
        // Scroll/resize/selection already computed both rects in
        // `invalidateOverlay`; reuse them for this paint instead of running the
        // line math again. A model change clears the flag, so the first draw
        // after an edit recomputes once and then caches.
        let viewport: NSRect
        let caret: NSRect?
        if overlayRectsAreCurrent {
            viewport = lastViewportRect
            caret = lastCaretRect.isEmpty ? nil : lastCaretRect
        } else {
            viewport = viewportRect() ?? .zero
            caret = caretRect()
            lastViewportRect = viewport
            lastCaretRect = caret ?? .zero
            overlayRectsAreCurrent = true
        }

        if !viewport.isEmpty {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).setFill()
            viewport.fill()

            let border = NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55).setStroke()
            border.stroke()
        }

        if let caret {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.75).setFill()
            NSRect(x: 0, y: caret.minY, width: 2, height: caret.height).fill()
        }
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
