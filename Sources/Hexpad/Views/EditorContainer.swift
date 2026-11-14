import AppKit
import HexpadKit

class EditorContainer: NSView {
    
    let scrollView: NSScrollView
    let textView: NSTextView
    let ruler: LineNumberGutter

    /// Used when no tab is selected, so the text view always has a storage.
    private let unboundStorage = NSTextStorage()

    /// The editor's body font. A document's NSTextStorage has no font of its
    /// own, and swapping one in makes NSTextView fall back to Helvetica 12, so
    /// bind and highlighting must restore this value explicitly.
    private(set) var bodyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    
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

    /// Points the editor at the document's shared buffer. The text view never
    /// receives a copy of the text: switching tabs swaps the storage under the
    /// layout manager, so the model and the visible editor are one buffer.
    func bind(to document: DocumentModel?) {
        let storage = document?.textStorage ?? unboundStorage
        guard let layoutManager = textView.layoutManager else {
            assertionFailure("Editor requires the TextKit 1 layout manager")
            return
        }
        guard layoutManager.textStorage !== storage else { return }
        layoutManager.replaceTextStorage(storage)
        applyBodyFont()
    }

    /// Changes the global editor font (zoom) and updates the visible buffer.
    func setBodyFont(_ font: NSFont) {
        bodyFont = font
        textView.font = font
        applyBodyFont()
    }

    /// Applies the body font to the currently shared buffer without touching
    /// syntax colours, so the text view never renders with AppKit's default.
    private func applyBodyFont() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttribute(.font, value: bodyFont,
                             range: NSRange(location: 0, length: storage.length))
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        
        textView.font = bodyFont
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
