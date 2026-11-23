import AppKit

/// Grid view backing the Character Panel. Renders the (possibly filtered)
/// character list for the focused editor's font and forwards double-clicks to
/// the panel's insert path.
final class CharacterGridView: NSView {

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("CharacterGridItem")

    var items: [CharacterPanelWindowController.CharacterEntry] = [] {
        didSet { collectionView.reloadData() }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 13) {
        didSet { collectionView.reloadData() }
    }

    var onInsert: ((CharacterPanelWindowController.CharacterEntry) -> Void)?

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 34, height: 34)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.setAccessibilityLabel("Character grid")
        collectionView.register(NSCollectionViewItem.self,
                                forItemWithIdentifier: Self.itemIdentifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        collectionView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
    }

    @objc private func itemClicked(_ sender: Any?) {
        guard let button = sender as? NSButton else { return }
        let index = button.tag
        guard items.indices.contains(index) else { return }
        onInsert?(items[index])
    }
}

extension CharacterGridView: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier,
                                          for: indexPath)
        let entry = items[indexPath.item]
        let button: NSButton
        if let existing = item.view as? NSButton {
            button = existing
        } else {
            button = NSButton(title: "", target: self, action: #selector(itemClicked(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = true
            item.view = button
        }
        button.title = String(entry.character)
        button.font = font
        button.tag = indexPath.item
        button.target = self
        button.action = #selector(itemClicked(_:))
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        guard items.indices.contains(indexPath.item) else { return }
        onInsert?(items[indexPath.item])
    }
}