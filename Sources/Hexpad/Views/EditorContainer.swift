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

    /// Fired when the visible character range changes (scroll or resize).
    var onViewportChange: (() -> Void)?
    /// Fired when the effective light/dark appearance changes.
    var onAppearanceChange: (() -> Void)?

    private var viewportObservers: [NSObjectProtocol] = []
    private var pendingViewportUpdate = false
    
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

    deinit {
        viewportObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Character range currently visible in the clip view, resolved through the
    /// layout manager rather than by guessing a character-per-pixel ratio.
    func visibleCharacterRange() -> NSRange {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: min(storage.length, 4_000))
        }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect,
                                                  in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        guard charRange.length > 0 else {
            // TextKit has not laid the view out yet; start at the top.
            return NSRange(location: 0, length: min(storage.length, 4_000))
        }
        return charRange
    }

    /// Applies theme chrome. Colors on the text itself are applied per visible
    /// viewport by the window controller.
    func apply(theme: Theme) {
        layer?.backgroundColor = theme.background.cgColor
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
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
        startViewportObservation()
    }

    // MARK: - Viewport observation

    private func startViewportObservation() {
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true

        let watched: [(Any, Notification.Name)] = [
            (clip, NSView.boundsDidChangeNotification),
            (clip, NSView.frameDidChangeNotification)
        ]
        for (object, name) in watched {
            viewportObservers.append(center.addObserver(forName: name,
                                                        object: object,
                                                        queue: .main) { [weak self] _ in
                self?.scheduleViewportChange()
            })
        }
    }

    /// Coalesces continuous scrolling into one viewport update. The controller
    /// still skips the work entirely while the viewport stays inside the
    /// already-highlighted band.
    private func scheduleViewportChange() {
        guard !pendingViewportUpdate else { return }
        pendingViewportUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingViewportUpdate = false
            self.onViewportChange?()
        }
    }
}
