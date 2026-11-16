import AppKit
import HexpadKit

/// Which side of the split view owns a tab store. The primary group is the
/// original single-group window; the secondary group only exists while the
/// split is open.
enum TabGroup {
    case primary
    case secondary
}

/// One side of the split: its own tab store, tab bar and editor container.
///
/// The TabStore design choice is two independent stores rather than one store
/// with group membership. Every existing command path already works against a
/// single `TabStore` (selection, undo, focus, session serialization), so a pane
/// pairs a store with the views that display it. Tabs move between groups by
/// moving the DocumentModel between the two stores; each document keeps its own
/// storage, undo manager, dirty state and editor state, so the groups edit
/// independently without a second model.
final class TabGroupPane {

    let group: TabGroup
    let tabStore: TabStore
    let tabBar: TabBarView
    let tabScrollView: NSScrollView
    let editor: EditorContainer

    /// The document currently bound to `editor`. Kept here (rather than in the
    /// controller) so undo routing can map a text view back to its own group.
    weak var boundDocument: DocumentModel?

    init(group: TabGroup, tabStore: TabStore = TabStore()) {
        self.group = group
        self.tabStore = tabStore

        let bar = TabBarView(tabStore: tabStore)
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = bar

        let editor = EditorContainer()

        // Width-following masks so interim resizes stay sane even before
        // viewDidLayout runs the authoritative pass.
        bar.autoresizingMask = [.width, .height]
        scroll.autoresizingMask = [.width, .minYMargin]
        editor.autoresizingMask = [.width, .height]

        tabBar = bar
        tabScrollView = scroll
        self.editor = editor
    }
}
