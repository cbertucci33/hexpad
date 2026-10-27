import AppKit
import HexpadKit

class TabBarView: NSView {
    
    private let tabStore: TabStore
    private var tabButtons: [TabButton] = []
    
    init(tabStore: TabStore) {
        self.tabStore = tabStore
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        NotificationCenter.default.addObserver(self, selector: #selector(documentsDidChange), name: NSNotification.Name("TabStoreDocumentsDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(selectedIndexDidChange), name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func fitWidthToClip() {
        let clipWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let totalTabsWidth = CGFloat(tabStore.count) * (140 + 2) - 2
        frame.size.width = max(totalTabsWidth, clipWidth)
    }

    func reloadTabs() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        
        let tabWidth: CGFloat = 140
        let spacing: CGFloat = 2
        let tabHeight = bounds.height
        
        for (index, doc) in tabStore.documents.enumerated() {
            let button = TabButton(doc: doc, index: index, tabWidth: tabWidth, tabHeight: tabHeight)
            button.frame = NSRect(x: CGFloat(index) * (tabWidth + spacing), y: 0, width: tabWidth, height: tabHeight)
            button.isSelected = index == tabStore.selectedIndex
            button.target = self
            button.action = #selector(tabClicked(_:))
            button.reorderDelegate = self
            addSubview(button)
            tabButtons.append(button)
        }
        
        fitWidthToClip()
    }

    // MARK: - Drag reorder

    /// TabStore.moveDocument existed from the start but nothing drove it.
    func moveTab(from source: Int, to destination: Int) {
        tabStore.moveDocument(from: source, to: destination)
        reloadTabs()
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
    }

    /// Index whose slot contains the given point in bar coordinates.
    func tabIndex(at point: NSPoint) -> Int? {
        let slot = 142.0
        guard point.x >= 0, point.x < CGFloat(tabButtons.count) * slot else { return nil }
        return min(tabButtons.count - 1, max(0, Int(point.x / slot)))
    }
    
    @objc private func tabClicked(_ sender: TabButton) {
        tabStore.selectedIndex = sender.index
        reloadTabs()
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
    }
    
    @objc private func documentsDidChange() {
        reloadTabs()
    }
    
    @objc private func selectedIndexDidChange() {
        for (i, btn) in tabButtons.enumerated() {
            btn.isSelected = i == tabStore.selectedIndex
        }
    }
}

class TabButton: NSButton {
    
    let doc: DocumentModel
    let index: Int
    let tabWidth: CGFloat
    let tabHeight: CGFloat
    
    private var titleLabel: NSTextField?
    private var dirtyIndicator: NSView?
    private var closeButton: NSButton?
    private var dragStart: NSPoint?
    private var draggedOut = false
    weak var reorderDelegate: TabBarView?
    
    init(doc: DocumentModel, index: Int, tabWidth: CGFloat, tabHeight: CGFloat) {
        self.doc = doc
        self.index = index
        self.tabWidth = tabWidth
        self.tabHeight = tabHeight
        super.init(frame: .zero)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        bezelStyle = .regularSquare
        sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        let title = NSTextField(labelWithString: doc.name)
        title.font = NSFont.systemFont(ofSize: 12)
        title.alignment = .left
        title.frame = NSRect(x: 8, y: (tabHeight - 16) / 2, width: tabWidth - 40, height: 16)
        addSubview(title)
        titleLabel = title
        
        let dot = NSView(frame: NSRect(x: tabWidth - 50, y: tabHeight / 2 - 3, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.isHidden = !doc.unsavedChanges
        addSubview(dot)
        dirtyIndicator = dot
        
        let closeBtn = NSButton(frame: NSRect(x: tabWidth - 18, y: tabHeight / 2 - 8, width: 16, height: 16))
        closeBtn.bezelStyle = .regularSquare
        closeBtn.title = "×"
        closeBtn.font = NSFont.systemFont(ofSize: 10)
        closeBtn.isBordered = false
        closeBtn.target = self
        closeBtn.action = #selector(closeTabClicked)
        addSubview(closeBtn)
        closeButton = closeBtn
        
        NotificationCenter.default.addObserver(self, selector: #selector(modifiedDidChange), name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
    }
    
    var isSelected: Bool = false {
        didSet {
            if isSelected {
                layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
            } else {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            }
        }
    }
    
    @objc private func closeTabClicked() {
        NotificationCenter.default.post(name: NSNotification.Name("TabCloseRequested"), object: nil, userInfo: ["index": index])
    }

    // MARK: - Drag reorder

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        draggedOut = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let here = convert(event.locationInWindow, from: nil)
        if abs(here.x - start.x) > 6 { draggedOut = true }
        guard draggedOut, let bar = reorderDelegate else { return }
        let inBar = bar.convert(event.locationInWindow, from: nil)
        if let target = bar.tabIndex(at: inBar), target != index {
            bar.moveTab(from: index, to: target)
        }
    }
    
    @objc private func modifiedDidChange() {
        dirtyIndicator?.isHidden = !doc.unsavedChanges
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            NSColor.systemBlue.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 0, y: 0))
            line.line(to: NSPoint(x: tabWidth, y: 0))
            line.lineWidth = 2
            line.stroke()
        }
    }
}
