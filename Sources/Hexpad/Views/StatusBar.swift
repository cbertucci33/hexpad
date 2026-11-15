import AppKit
import HexpadKit

class StatusBar: NSView {
    
    private var positionLabel: NSTextField?
    private var selectionLabel: NSTextField?
    private var eolLabel: NSTextField?
    private var encodingLabel: NSTextField?
    private var languageLabel: NSTextField?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        let font = NSFont.systemFont(ofSize: 11)
        let height = bounds.height
        
        let pos = NSTextField(labelWithString: "Ln 1, Col 1")
        pos.font = font
        pos.frame = NSRect(x: 8, y: (height - 14) / 2, width: 120, height: 14)
        addSubview(pos)
        positionLabel = pos
        
        let sel = NSTextField(labelWithString: "0 selected")
        sel.font = font
        sel.frame = NSRect(x: 136, y: (height - 14) / 2, width: 100, height: 14)
        addSubview(sel)
        selectionLabel = sel
        
        let eol = NSTextField(labelWithString: "LF")
        eol.font = font
        eol.frame = NSRect(x: 244, y: (height - 14) / 2, width: 40, height: 14)
        addSubview(eol)
        eolLabel = eol
        
        let enc = NSTextField(labelWithString: "UTF-8")
        enc.font = font
        enc.frame = NSRect(x: 292, y: (height - 14) / 2, width: 70, height: 14)
        addSubview(enc)
        encodingLabel = enc
        
        let lang = NSTextField(labelWithString: "Plain Text")
        lang.font = font
        lang.frame = NSRect(x: 370, y: (height - 14) / 2, width: 100, height: 14)
        addSubview(lang)
        languageLabel = lang

        let separator = NSView(frame: .zero)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.autoresizingMask = [.width, .minYMargin]
        separatorView = separator
        addSubview(separator)
    }

    private var separatorView: NSView?

    /// Labels are laid out here, not in setupUI: the bar is created with a
    /// zero-height frame and StatusBar never relaid out, so every label used
    /// to sit at y=-7 (half below the bar) with a zero-width separator.
    override func layout() {
        super.layout()
        let h = bounds.height
        let labelHeight: CGFloat = 14
        let y = max(0, (h - labelHeight) / 2)
        let xs: [(CGFloat, CGFloat)] = [(8, 120), (136, 100), (244, 40), (292, 70), (370, 100)]
        let labels = [positionLabel, selectionLabel, eolLabel, encodingLabel, languageLabel]
        for (label, geo) in zip(labels, xs) {
            label?.frame = NSRect(x: geo.0, y: y, width: geo.1, height: labelHeight)
        }
        separatorView?.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
    }
    
    func update(with doc: DocumentModel?, textView: NSTextView?) {
        guard let textView = textView else { return }
        
        let selRange = textView.selectedRange
        let text = textView.string
        // GutterGeometry is the single source of truth for line math (it is
        // unit-tested and UTF-16 aware); derive the caret's 1-based line and
        // 1-based column from it.
        let line = GutterGeometry.logicalLine(of: selRange.location, in: text)
        let col = selRange.location - GutterGeometry.firstCharIndex(of: line, in: text) + 1
        positionLabel?.stringValue = "Ln \(line), Col \(col)"
        
        if selRange.length > 0 {
            selectionLabel?.stringValue = "\(selRange.length) selected"
        } else {
            selectionLabel?.stringValue = "0 selected"
        }
        
        eolLabel?.stringValue = doc?.eolType ?? "LF"
        encodingLabel?.stringValue = doc?.encoding ?? "UTF-8"
        languageLabel?.stringValue = doc?.language ?? "Plain Text"
    }
}
