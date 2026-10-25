import AppKit
import HexpadKit

class EditorContainer: NSView {
    
    let scrollView: NSScrollView
    let textView: NSTextView
    let ruler: LineNumberGutter
    
    init() {
        scrollView = NSScrollView()
        textView = NSTextView()
        ruler = LineNumberGutter(textView: textView)
        
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.drawsBackground = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: LineNumberGutter.width, bottom: 0, right: 0)
        scrollView.frame = NSRect(x: LineNumberGutter.width, y: 0, width: 720, height: 500)
        
        ruler.frame = NSRect(x: 0, y: 0, width: LineNumberGutter.width, height: 500)
        ruler.autoresizingMask = [.height]
        
        addSubview(ruler)
        addSubview(scrollView)
    }
}
