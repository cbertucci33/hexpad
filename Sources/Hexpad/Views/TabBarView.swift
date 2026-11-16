import AppKit
import HexpadKit

class TabBarView: NSView {
    
    private let tabStore: TabStore
    private var tabButtons: [TabButton] = []

    /// The other group's bar while the split view is open. Drags that leave
    /// this bar over its sibling move the tab between the two TabStores.
    weak var siblingTabBar: TabBarView?
    /// Called when the user interacts with this bar, so the controller can make
    /// this group the focused one.
    var onFocus: (() -> Void)?
    /// Called after a tab selection/reorder/transfer so the controller can
    /// rebind the affected editors.
    var onChange: (() -> Void)?

    /// Live drag-reorder preview. The store is not mutated until mouseUp; the
    /// buttons are only re-slotted for visual feedback.
    private var previewOrder: [TabButton]?
    private var previewDraggedButton: TabButton?
    private var previewMonitor: Any?
    
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
        if let previewMonitor {
            NSEvent.removeMonitor(previewMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    func fitWidthToClip() {
        let clipWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let totalTabsWidth = CGFloat(tabStore.count) * (140 + 2) - 2
        frame.size.width = max(totalTabsWidth, clipWidth)
    }

    func reloadTabs() {
        finishDragPreview()
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
        onChange?()
    }

    // MARK: - Drag preview

    /// Starts a same-bar drag. The store is untouched until `commitDragPreview`
    /// so crossing many slots costs only frame changes, not a full controller
    /// rebind and tab reload per event.
    func beginDragPreview(from index: Int) {
        guard previewOrder == nil,
              let button = tabButtons.first(where: { $0.index == index }) else { return }
        previewOrder = tabButtons
        previewDraggedButton = button
        previewMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.commitDragPreview()
            return event
        }
    }

    /// Moves the dragged button to a visual slot without touching the store.
    func previewDrag(to index: Int) {
        guard var order = previewOrder,
              let dragged = previewDraggedButton,
              let from = order.firstIndex(where: { $0 === dragged }) else { return }
        let target = min(max(0, index), order.count - 1)
        guard target != from else { return }
        order.remove(at: from)
        order.insert(dragged, at: target)
        previewOrder = order
        layoutPreview(order)
    }

    /// Commits the previewed order once, on mouseUp. Calls `onChange` exactly
    /// once through `moveTab`; a drag that ends where it started does not.
    func commitDragPreview() {
        guard let order = previewOrder, let dragged = previewDraggedButton else { return }
        let destination = order.firstIndex(where: { $0 === dragged }) ?? dragged.index
        let source = dragged.index
        finishDragPreview()
        if source != destination {
            moveTab(from: source, to: destination)
        } else {
            reloadTabs()
        }
    }

    /// Drops a pending preview when a drag turns into a cross-group transfer.
    func discardDragPreview() {
        finishDragPreview()
    }

    private func finishDragPreview() {
        if let previewMonitor {
            NSEvent.removeMonitor(previewMonitor)
        }
        previewMonitor = nil
        previewOrder = nil
        previewDraggedButton = nil
    }

    private func layoutPreview(_ order: [TabButton]) {
        let tabWidth: CGFloat = 140
        let spacing: CGFloat = 2
        for (slot, button) in order.enumerated() {
            button.frame.origin = NSPoint(x: CGFloat(slot) * (tabWidth + spacing), y: 0)
        }
    }

    /// Updates only the existing dirty dots; no view or store churn. Typing
    /// uses this instead of `reloadTabs()`.
    func updateDirtyIndicators() {
        tabButtons.forEach { $0.refreshDirtyIndicator() }
    }

    /// Index whose slot contains the given point in bar coordinates.
    func tabIndex(at point: NSPoint) -> Int? {
        let slot = 142.0
        guard point.x >= 0, point.x < CGFloat(tabButtons.count) * slot else { return nil }
        return min(tabButtons.count - 1, max(0, Int(point.x / slot)))
    }

    /// Insertion index for a drop at `point`, clamped to the current tab count
    /// so a drop past the last tab appends.
    func dropIndex(at point: NSPoint) -> Int {
        guard let index = tabIndex(at: point) else { return tabStore.count }
        return min(index, tabStore.count)
    }

    /// Accepts a tab dragged in from the sibling group's bar.
    func insertDroppedDocument(_ doc: DocumentModel, at index: Int) {
        tabStore.insertDocument(doc, at: index)
        reloadTabs()
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
        onFocus?()
        onChange?()
    }

    /// Moves the tab at `sourceIndex` into `target`'s store at `targetIndex`.
    /// The document identity check makes a second drag event after the button
    /// was removed by `reloadTabs` a no-op instead of moving a neighbour.
    func transferTab(at sourceIndex: Int, doc: DocumentModel, to target: TabBarView, at targetIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < tabStore.count,
              tabStore.documents[sourceIndex] === doc else { return }
        tabStore.removeDocument(at: sourceIndex)
        target.insertDroppedDocument(doc, at: targetIndex)
        reloadTabs()
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
        onChange?()
    }
    
    @objc private func tabClicked(_ sender: TabButton) {
        onFocus?()
        tabStore.selectedIndex = sender.index
        for (i, btn) in tabButtons.enumerated() {
            btn.isSelected = i == tabStore.selectedIndex
        }
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
        onChange?()
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        // The bar identity rides along so closing a tab in the unfocused group
        // targets that group's store, not whichever group happens to be focused.
        var userInfo: [AnyHashable: Any] = ["index": index]
        if let bar = reorderDelegate { userInfo["tabBar"] = bar }
        NotificationCenter.default.post(name: NSNotification.Name("TabCloseRequested"),
                                        object: nil,
                                        userInfo: userInfo)
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

        // Cross-group drop: the pointer is over the sibling bar. This runs
        // before same-bar reorder because the two bars never overlap.
        if let sibling = bar.siblingTabBar {
            bar.onFocus?()
            let inSibling = sibling.convert(event.locationInWindow, from: nil)
            if sibling.bounds.contains(inSibling) {
                sibling.onFocus?()
                bar.discardDragPreview()
                bar.transferTab(at: index, doc: doc, to: sibling,
                                at: sibling.dropIndex(at: inSibling))
                return
            }
        }

        let inBar = bar.convert(event.locationInWindow, from: nil)
        if let target = bar.tabIndex(at: inBar) {
            bar.beginDragPreview(from: index)
            bar.previewDrag(to: target)
        }
    }

    override func mouseUp(with event: NSEvent) {
        reorderDelegate?.commitDragPreview()
        super.mouseUp(with: event)
    }
    
    /// Updates this button's dot without rebuilding the bar. Called on typing.
    func refreshDirtyIndicator() {
        dirtyIndicator?.isHidden = !doc.unsavedChanges
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
