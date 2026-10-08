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
        
        let separator = NSView(frame: NSRect(x: 0, y: height - 1, width: bounds.width, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)
    }
    
    func update(with doc: DocumentModel?, textView: NSTextView?) {
        guard let textView = textView else { return }
        
        let selRange = textView.selectedRange
        let text = textView.string as NSString
        let line = lineNumberAtPosition(text, position: selRange.location)
        let col = columnAtPosition(text, position: selRange.location)
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
    
    private func lineNumberAtPosition(_ text: NSString, position: Int) -> Int {
        var lineNum = 1
        var loc = 0
        while loc < position {
            let lineRange = text.lineRange(for: NSRange(location: loc, length: 0))
            if lineRange.location == NSNotFound { break }
            lineNum += 1
            loc = lineRange.upperBound
        }
        return lineNum
    }
    
    private func columnAtPosition(_ text: NSString, position: Int) -> Int {
        let lineRange = text.lineRange(for: NSRange(location: position, length: 0))
        return position - lineRange.location + 1
    }
}
