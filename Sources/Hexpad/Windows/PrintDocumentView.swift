import AppKit

/// Paginated printout of a document (or its selection).
///
/// The view is flipped: page 1 occupies y = 0...792, page 2 the next band, and
/// so on. `NSPrintOperation` asks `knowsPageRange`/`rectForPage` for each page
/// and then calls `draw(_:)` with that page's rect; this view draws the header,
/// the text fragments that belong to the page, and the footer itself. Keeping
/// the pagination in this view (rather than in an offscreen text view) is what
/// makes header/footer and line numbers line up with the printed text.
///
/// Geometry is US Letter at 0.5in margins, as specified. The header sits in the
/// top margin band and the footer in the bottom one, so the body never overlaps
/// either.
final class PrintDocumentView: NSView {

    // MARK: - Page geometry

    static let pageSize = NSSize(width: 612, height: 792) // 8.5 x 11 in, points
    private static let margin: CGFloat = 36                 // 0.5 in
    private static let contentTop: CGFloat = 52             // below the header band
    private static let contentBottomInset: CGFloat = 52     // above the footer band
    private static let lineNumberGutter: CGFloat = 38

    private var contentHeight: CGFloat {
        Self.pageSize.height - Self.contentTop - Self.contentBottomInset
    }

    private var contentWidth: CGFloat {
        Self.pageSize.width - Self.margin * 2 - (showsLineNumbers ? Self.lineNumberGutter : 0)
    }

    // MARK: - Input

    private let text: String
    private let font: NSFont
    private let fileName: String
    private let filePath: String?
    /// Line numbers in the printout (N++ prints them by default).
    let showsLineNumbers: Bool
    /// Document line number of the first printed line. 1 for the whole
    /// document, or the selection's actual starting line so printed numbers
    /// still match the editor.
    private let firstLineNumber: Int

    // MARK: - Layout

    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private var lineStarts: [Int] = []
    private var pageCount = 1

    private struct PageLine {
        let glyphRange: NSRange
        let y: CGFloat
        let page: Int
        let lineNumber: String?
    }
    private var pageLines: [PageLine] = []

    init(text: String,
         font: NSFont,
         fileName: String,
         filePath: String?,
         showsLineNumbers: Bool = true,
         firstLineNumber: Int = 1) {
        self.text = text
        self.font = font
        self.fileName = fileName
        self.filePath = filePath
        self.showsLineNumbers = showsLineNumbers
        self.firstLineNumber = max(1, firstLineNumber)

        storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black
        ])
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false

        super.init(frame: NSRect(x: 0, y: 0, width: Self.pageSize.width, height: Self.pageSize.height))

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.containerSize = NSSize(width: contentWidth,
                                             height: CGFloat.greatestFiniteMagnitude)
        buildLineStarts()
        paginate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Flipped so page bands and TextKit's downward line layout share one
    /// coordinate direction.
    override var isFlipped: Bool { true }

    // MARK: - Measurement

    private func buildLineStarts() {
        lineStarts = [0]
        let nsText = text as NSString
        guard nsText.length > 0 else { return }
        for index in 0..<nsText.length where nsText.character(at: index) == 0x0A {
            lineStarts.append(index + 1)
        }
    }

    /// Logical (source) line number for a character index.
    private func documentLineNumber(at index: Int) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        var line = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= index {
                line = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return firstLineNumber + line
    }

    /// Whether `index` is the first character of a source line. Wrapped
    /// continuations share their source line's number and are not labelled
    /// again, matching a line-numbered editor.
    private func isLineStart(_ index: Int) -> Bool {
        guard !lineStarts.isEmpty else { return false }
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] == index { return true }
            if lineStarts[mid] < index { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }

    private func paginate() {
        layoutManager.ensureLayout(for: textContainer)
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            pageCount = 1
            pageLines = []
            return
        }

        var lines: [PageLine] = []
        var page = 0
        var pageStartY: CGFloat = 0

        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: glyphCount)
        ) { rect, usedRect, _, glyphRange, _ in
            guard glyphRange.length > 0 else { return }
            let fragmentHeight = max(rect.height, usedRect.height)

            // Start a new page when this fragment would overflow the current
            // one. The first fragment of a page always stays, even if it is
            // itself taller than the body (pathological huge font).
            if rect.minY > pageStartY,
               rect.minY - pageStartY + fragmentHeight > self.contentHeight {
                page += 1
                pageStartY = rect.minY
            }

            let charRange = self.layoutManager.characterRange(forGlyphRange: glyphRange,
                                                              actualGlyphRange: nil)
            let number: String?
            if self.showsLineNumbers, self.isLineStart(charRange.location),
               let logical = self.documentLineNumber(at: charRange.location) {
                number = "\(logical)"
            } else {
                number = nil
            }

            lines.append(PageLine(glyphRange: glyphRange,
                                  y: rect.minY - pageStartY,
                                  page: page,
                                  lineNumber: number))
        }

        pageLines = lines
        pageCount = max(1, page + 1)
        frame = NSRect(x: 0,
                       y: 0,
                       width: Self.pageSize.width,
                       height: Self.pageSize.height * CGFloat(pageCount))
    }

    // MARK: - Pagination hooks

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0,
               y: CGFloat(max(0, page - 1)) * Self.pageSize.height,
               width: Self.pageSize.width,
               height: Self.pageSize.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The page rect NSPrintOperation hands us starts at a multiple of the
        // page height (the view is flipped).
        let pageIndex = max(0, Int(floor(dirtyRect.minY / Self.pageSize.height)))
        let pageOriginY = CGFloat(pageIndex) * Self.pageSize.height
        let pageRect = NSRect(x: 0, y: pageOriginY,
                              width: Self.pageSize.width, height: Self.pageSize.height)

        NSColor.white.setFill()
        pageRect.fill()
        drawHeader(pageOriginY: pageOriginY)
        drawPageLines(pageIndex: pageIndex, pageOriginY: pageOriginY)
        drawFooter(pageIndex: pageIndex, pageOriginY: pageOriginY)
    }

    private func drawHeader(pageOriginY: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.darkGray
        ]
        let availableWidth = Self.pageSize.width - Self.margin * 2
        var header = fileName
        if let path = filePath, !path.isEmpty {
            let candidate = "\(fileName)   —   \(path)"
            if (candidate as NSString).size(withAttributes: attributes).width <= availableWidth {
                header = candidate
            }
        }
        let y = pageOriginY + (Self.margin - 12)
        NSAttributedString(string: header, attributes: attributes)
            .draw(at: NSPoint(x: Self.margin, y: y))
    }

    private func drawPageLines(pageIndex: Int, pageOriginY: CGFloat) {
        let contentRect = NSRect(x: Self.margin,
                                 y: pageOriginY + Self.contentTop,
                                 width: Self.pageSize.width - Self.margin * 2,
                                 height: contentHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: contentRect).addClip()

        let textX = Self.margin + (showsLineNumbers ? Self.lineNumberGutter : 0)
        let baseY = pageOriginY + Self.contentTop

        for line in pageLines where line.page == pageIndex {
            let lineY = baseY + line.y
            if let number = line.lineNumber {
                let numberAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: max(7, font.pointSize - 2),
                                                            weight: .regular),
                    .foregroundColor: NSColor.gray
                ]
                let numberText = NSAttributedString(string: number, attributes: numberAttributes)
                let numberWidth = numberText.size().width
                numberText.draw(at: NSPoint(x: Self.margin + Self.lineNumberGutter - 4 - numberWidth,
                                            y: lineY))
            }
            layoutManager.drawGlyphs(forGlyphRange: line.glyphRange,
                                     at: NSPoint(x: textX, y: lineY))
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFooter(pageIndex: Int, pageOriginY: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.darkGray
        ]
        let footer = "Page \(pageIndex + 1) of \(pageCount)"
        let size = (footer as NSString).size(withAttributes: attributes)
        let y = pageOriginY + Self.pageSize.height - Self.margin + 4
        NSAttributedString(string: footer, attributes: attributes)
            .draw(at: NSPoint(x: Self.pageSize.width - Self.margin - size.width, y: y))
    }
}
