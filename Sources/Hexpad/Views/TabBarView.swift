import AppKit
import HexpadKit

/// Layer backgrounds take a `CGColor`, which freezes the appearance it was
/// resolved in. System colours are dynamic, so any chrome that stores one must
/// re-resolve it through the owning view's appearance instead of converting
/// once at init.
enum ChromeColor {
    static func cgColor(_ color: NSColor, for appearance: NSAppearance) -> CGColor {
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    /// Same freeze-avoidance for a dynamic colour stored on a view property
    /// (e.g. `textColor`): resolve it to a concrete colour for `appearance`.
    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        NSColor(cgColor: cgColor(color, for: appearance)) ?? color
    }
}

class TabBarView: NSView {
    
    private let tabStore: TabStore
    private var tabButtons: [TabButton] = []

    /// Creation moments of the bar's tabs, keyed by document identity. The
    /// bar records each document's first sight here and every later rebuild
    /// of the buttons reuses the stored date, so a tab's tooltip "created"
    /// time does not drift with `reloadTabs()`. Entries for tabs that closed
    /// are dropped on the next reload.
    private var creationDates: [UUID: Date] = [:]

    /// The other group's bar while the split view is open. Drags that leave
    /// this bar over its sibling move the tab between the two TabStores.
    weak var siblingTabBar: TabBarView?
    /// Called when the user interacts with this bar, so the controller can make
    /// this group the focused one.
    var onFocus: (() -> Void)?
    /// Called after a tab selection/reorder/transfer so the controller can
    /// rebind the affected editors.
    var onChange: (() -> Void)?
    /// Called when the user double-clicks the empty part of the bar, so the
    /// controller can create a new tab. The bar deliberately has no controller
    /// reference; like `onFocus`/`onChange`, this per-pane closure is the bridge.
    var onNewTabRequested: (() -> Void)?
    /// Called with the index of a right-clicked tab. The owning pane builds the
    /// tab's context menu (and focuses its group) before returning it. The bar
    /// deliberately has no controller reference: this per-pane closure is the
    /// whole bridge.
    var contextMenuProvider: ((Int) -> NSMenu?)?
    /// The menu produced by the most recent right-click. Keeping it here lets
    /// the presenting code (and tests) inspect exactly what was built without
    /// opening a modal menu during a unit test.
    private(set) var lastContextMenu: NSMenu?

    /// Settings > Tab Bar: drag reordering disabled while locked.
    var lockTabBar = false
    /// Settings > Tab Bar: a double-click on a tab posts the close request.
    var doubleClickTabCloses = false
    /// Settings > Tab Bar: caption limit; 0 is unlimited.
    var maxTabLabelLength = 0
    /// Settings > Tab Bar: which tabs reveal their × button. Applied to the
    /// existing buttons as well as on the next ``reloadTabs()`` so a preference
    /// change takes effect without rebuilding the whole bar.
    public var closeButtonVisibility: CloseButtonVisibility = .always {
        didSet {
            tabButtons.forEach { $0.closeButtonVisibility = closeButtonVisibility }
        }
    }

    /// Live drag-reorder preview. The store is not mutated until mouseUp; the
    /// buttons are only re-slotted for visual feedback.
    private var previewOrder: [TabButton]?
    private var previewDraggedButton: TabButton?
    private var previewMonitor: Any?
    
    init(tabStore: TabStore) {
        self.tabStore = tabStore
        super.init(frame: .zero)
        wantsLayer = true
        refreshChromeColors()
        
        NotificationCenter.default.addObserver(self, selector: #selector(selectedIndexDidChange), name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)), name: .preferencesDidChange, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Re-resolves the bar's background for the current appearance. The layer
    /// stores a CGColor, so without this the bar keeps the colours it was born
    /// with while the editor and minimap follow a light/dark switch.
    func refreshChromeColors() {
        layer?.backgroundColor = ChromeColor.cgColor(.controlBackgroundColor,
                                                     for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
        tabButtons.forEach { $0.refreshChromeColors() }
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

        // Creation is tracked per document, not per button: drop entries for
        // tabs that closed, then record each present document's first-sight
        // moment so the rebuilt buttons show the same "created" time.
        let presentIDs = Set(tabStore.documents.map { $0.id })
        creationDates = creationDates.filter { presentIDs.contains($0.key) }

        let tabWidth: CGFloat = 140
        let spacing: CGFloat = 2
        let tabHeight = bounds.height

        for (index, doc) in tabStore.documents.enumerated() {
            let created = creationDates[doc.id] ?? Date()
            creationDates[doc.id] = created
            let button = TabButton(doc: doc,
                                   index: index,
                                   tabWidth: tabWidth,
                                   tabHeight: tabHeight,
                                   maxLabelLength: maxTabLabelLength,
                                   closeButtonVisibility: closeButtonVisibility,
                                   created: created)
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

    /// Double-clicking the empty part of the bar creates a new tab (Notepad++
    /// behaviour). A click that lands on a tab button belongs to that button's
    /// own `mouseDown` (selection, drag, double-click-to-close), so only the
    /// no-button case is ours. Empty space has no drag state, so we return
    /// without calling `super`.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2,
           tabButtons.first { $0.frame.contains(convert(event.locationInWindow, from: nil)) } == nil {
            onNewTabRequested?()
            return
        }
        super.mouseDown(with: event)
    }
    
    // MARK: - Drag reorder

    /// TabStore.moveDocument existed from the start but nothing drove it.
    func moveTab(from source: Int, to destination: Int) {
        // A reorder moves documents, not the selection index. Follow the
        // selected document to its new slot, otherwise dragging the active tab
        // to another position leaves a different tab active after the drop.
        let selectedDocument = tabStore.selectedDocument
        tabStore.moveDocument(from: source, to: destination)
        if let selectedDocument,
           let newIndex = tabStore.documents.firstIndex(where: { $0 === selectedDocument }) {
            tabStore.selectedIndex = newIndex
        }
        reloadTabs()
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
        onChange?()
    }

    // MARK: - Drag preview

    /// Starts a same-bar drag. The store is untouched until `commitDragPreview`
    /// so crossing many slots costs only frame changes, not a full controller
    /// rebind and tab reload per event.
    func beginDragPreview(from index: Int) {
        guard !lockTabBar,
              previewOrder == nil,
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
        // Rebind before focusing: inserting selects the incoming document, so
        // focus chrome run against the pane's old binding would highlight the
        // new text into the previous buffer.
        onChange?()
        onFocus?()
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
    
    /// Selects `index` and notifies observers. Left-click and right-click
    /// both funnel through here, so one gesture can never select twice.
    private func selectTab(at index: Int) {
        onFocus?()
        tabStore.selectedIndex = index
        for (i, btn) in tabButtons.enumerated() {
            btn.isSelected = i == tabStore.selectedIndex
        }
        NotificationCenter.default.post(name: NSNotification.Name("TabStoreSelectedIndexDidChange"), object: nil)
        onChange?()
    }

    @objc private func tabClicked(_ sender: TabButton) {
        selectTab(at: sender.index)
    }

    /// Right-click entry point: select the clicked tab once, then ask the
    /// owning pane for its menu. The provider focuses this pane's group before
    /// building, so every action and validation sees the right document even
    /// when the click lands in the unfocused split group.
    @discardableResult
    func showContextMenu(for button: TabButton) -> NSMenu? {
        selectTab(at: button.index)
        let menu = contextMenuProvider?(button.index)
        lastContextMenu = menu
        return menu
    }
    
    @objc private func selectedIndexDidChange() {
        for (i, btn) in tabButtons.enumerated() {
            btn.isSelected = i == tabStore.selectedIndex
        }
    }

    /// Live apply for the close-button preference. The controller also sets
    /// this in `refreshTabBar()`, but observing directly means a change to this
    /// option alone does not have to wait for that refresh to be triggered.
    @objc private func preferencesDidChange(_ note: Notification) {
        guard let preferences = note.object as? Preferences else { return }
        closeButtonVisibility = preferences.closeButtonVisibility
    }
}

class TabButton: NSButton {
    
    let doc: DocumentModel
    let index: Int
    let tabWidth: CGFloat
    let tabHeight: CGFloat
    let maxLabelLength: Int

    /// The moment this tab was first seen by its bar. `DocumentModel` has no
    /// creation timestamp, so for a buffer that has never been saved this is
    /// the honest meaning of "created": when the document was opened in a
    /// tab. Passed in by the bar, which keys the moment by document identity
    /// so it survives the bar's rebuilds instead of being stamped with the
    /// rebuild time.
    private let created: Date

    /// `.medium`/`.short` with the current locale is the same display format
    /// the inspector uses for timestamps. Cached because `modifiedDidChange`
    /// fires on every edit and rebuilding a formatter there would be wasteful.
    private static let tooltipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter
    }()

    /// Settings > Tab Bar: which tabs reveal their × button.
    var closeButtonVisibility: CloseButtonVisibility = .always {
        didSet { updateCloseButtonVisibility() }
    }
    /// True while the pointer is inside this tab's bounds. Used only by the
    /// `.activeAndHover` mode; tracking is installed in `setupUI()`.
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    private var titleLabel: NSTextField?
    private var dirtyIndicator: NSView?
    /// Internal so the preference tests can assert its visibility directly.
    var closeButton: NSButton?
    private var dragStart: NSPoint?
    private var draggedOut = false
    weak var reorderDelegate: TabBarView?

    init(doc: DocumentModel,
         index: Int,
         tabWidth: CGFloat,
         tabHeight: CGFloat,
         maxLabelLength: Int = 0,
         closeButtonVisibility: CloseButtonVisibility = .always,
         created: Date = Date()) {
        self.doc = doc
        self.index = index
        self.tabWidth = tabWidth
        self.tabHeight = tabHeight
        self.maxLabelLength = maxLabelLength
        self.closeButtonVisibility = closeButtonVisibility
        self.created = created
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
        // The button's own background is a layer colour; without an explicit
        // layer the assignment below would go to nil in an unhosted view.
        wantsLayer = true
        // NSButton starts with a stock "Button" title. The real tab caption is
        // the NSTextField below; leaving the cell title in place draws that
        // stock word underneath it (and exposes title "Button" to accessibility).
        title = ""
        // Left-click is the only NSButton action. Right-click is handled by
        // `rightMouseDown` below, which selects the tab and presents the
        // context menu in one path; a .rightMouseUp action here would select
        // the tab a second time (or fire instead of the menu).
        sendAction(on: [.leftMouseUp])
        
        let title = NSTextField(labelWithString: TabLabel.truncated(doc.name,
                                                                    maxLength: maxLabelLength))
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
        
        // Hover tracking for `.activeAndHover`. `.inVisibleRect` keeps the area
        // correct even though the frame is assigned after init in reloadTabs().
        let hoverArea = NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil)
        addTrackingArea(hoverArea)
        hoverTrackingArea = hoverArea

        NotificationCenter.default.addObserver(self, selector: #selector(modifiedDidChange), name: NSNotification.Name("DocumentModifiedDidChange"), object: nil)
        refreshChromeColors()
        updateCloseButtonVisibility()
        refreshToolTip()
    }

    /// Hover tooltip: the full on-disk path for a saved document (Notepad++
    /// parity), otherwise the buffer name plus when this tab was created.
    /// Tooltips are static strings in AppKit, so this is recomputed on the
    /// existing modified-did-change observer to catch a "Save As" that gives
    /// an untitled buffer a path while its button is still alive.
    private func refreshToolTip() {
        if let path = doc.filePath?.path {
            toolTip = path
            return
        }
        // `isUntitled` is currently derived from `filePath`, so it is always
        // true in this branch; the name string is what distinguishes the
        // default "Untitled" buffer from one renamed before its first save.
        let label = doc.isUntitled && doc.name == "Untitled" ? "Untitled" : doc.name
        let time = Self.tooltipDateFormatter.string(from: created)
        toolTip = "\(label) — created \(time)"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateCloseButtonVisibility()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateCloseButtonVisibility()
        super.mouseExited(with: event)
    }

    /// The × is always shown in the default mode. In `.activeAndHover` it is
    /// shown only for the selected tab or while the pointer is over this tab.
    /// Only `isHidden` changes; frame math, the dirty dot and the label are
    /// deliberately left untouched.
    private func updateCloseButtonVisibility() {
        guard let closeButton else { return }
        switch closeButtonVisibility {
        case .always:
            closeButton.isHidden = false
        case .activeAndHover:
            closeButton.isHidden = !(isSelected || isHovered)
        }
    }
    
    var isSelected: Bool = false {
        didSet {
            refreshChromeColors()
            updateCloseButtonVisibility()
            // The underline is drawn in draw(_:), so changing the layer colour
            // alone leaves it under the previously selected tab.
            needsDisplay = true
        }
    }

    /// Resolves the tab's background and caption for the current appearance.
    /// Called on selection changes and whenever the effective appearance
    /// changes; the CGColor snapshot would otherwise keep the old light/dark
    /// value.
    func refreshChromeColors() {
        let color: NSColor = isSelected ? .selectedContentBackgroundColor : .controlBackgroundColor
        layer?.backgroundColor = ChromeColor.cgColor(color, for: effectiveAppearance)
        // A selected tab sits on the accent background, where the stock
        // labelColor (near-black in Light) is unreadable. White reads on the
        // accent in both appearances; unselected tabs keep labelColor.
        let titleColor: NSColor = isSelected ? .white : .labelColor
        titleLabel?.textColor = ChromeColor.resolved(titleColor, for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
        needsDisplay = true
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

    /// Right-click is owned entirely here: we never call `super`, so
    /// NSButton's rightMouseUp tracking cannot also send `tabClicked`. The bar
    /// selects the tab once and hands back the menu; AppKit only sees the menu
    /// when we explicitly pop it (an unhosted button in a test has no window,
    /// so the test just inspects `bar.lastContextMenu`).
    override func rightMouseDown(with event: NSEvent) {
        guard let bar = reorderDelegate else {
            super.rightMouseDown(with: event)
            return
        }
        let menu = bar.showContextMenu(for: self)
        if let menu, let window, window.isVisible {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// Middle-click closes the tab through the exact same path as the × button:
    /// a "TabCloseRequested" carrying this bar and index, which the controller
    /// handles (focusing the owning group before closing).
    override func otherMouseDown(with event: NSEvent) {
        closeTabClicked()
    }

    override func mouseDown(with event: NSEvent) {
        // Settings > Tab Bar > double-click to close. Handled before the
        // button's tracking so the first click does not also start a drag.
        if event.clickCount == 2, reorderDelegate?.doubleClickTabCloses == true {
            closeTabClicked()
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        draggedOut = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let here = convert(event.locationInWindow, from: nil)
        if abs(here.x - start.x) > 6 { draggedOut = true }
        guard draggedOut, let bar = reorderDelegate, !bar.lockTabBar else { return }

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
        refreshToolTip()
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
        // Per-tab colour bar (View > Tab > Apply Color). Three points high on
        // the bottom edge; it replaces the selection underline's look when a
        // colour is set, so the tab still reads as the active one. Resolved on
        // every draw, and `viewDidChangeEffectiveAppearance` requests a redraw,
        // so a light/dark switch gets the matching palette.
        if let colorIndex = doc.tabColorIndex,
           let color = TabColorPalette.color(for: colorIndex,
                                             appearance: effectiveAppearance) {
            color.setFill()
            NSRect(x: 0, y: 0, width: tabWidth, height: 3).fill()
        }
    }
}
