import Foundation

/// Which open tabs a bulk-close command should target. Ordering always follows
/// the store's `documents` array, which is the tab order shown to the user.
public enum TabCloseScope: Equatable {
    /// Every tab except the selected one.
    case allButActive
    /// Every tab except pinned ones. Pinning is not implemented yet, so this
    /// currently targets the same tabs as `.allButActive` (the active tab is
    /// kept); once pins exist only `isPinned` documents should be skipped.
    case allButPinned
    /// Tabs before the selected one, nearest last (tab order).
    case toLeftOfActive
    /// Tabs after the selected one, nearest first (tab order).
    case toRightOfActive
    /// Every tab without unsaved changes, including the active tab when clean.
    case unchanged
}

/// Manages a collection of open documents as tabs
public final class TabStore: ObservableObject {
    @Published public var documents: [DocumentModel] = []
    @Published public var selectedIndex: Int = 0
    
    public var selectedDocument: DocumentModel? {
        guard selectedIndex >= 0, selectedIndex < documents.count else { return nil }
        return documents[selectedIndex]
    }
    
    public var isEmpty: Bool { documents.isEmpty }
    public var count: Int { documents.count }
    
    public init() {}
    
    public func addDocument(_ doc: DocumentModel) {
        documents.append(doc)
        selectedIndex = documents.count - 1
    }

    /// Inserts `doc` at `index` and selects it. Used by the split view when a
    /// tab is dragged from one group's bar into the other, where the drop
    /// position matters (unlike `addDocument`, which always appends).
    public func insertDocument(_ doc: DocumentModel, at index: Int) {
        let clamped = max(0, min(index, documents.count))
        documents.insert(doc, at: clamped)
        selectedIndex = clamped
    }
    
    public func removeDocument(at index: Int) {
        guard index >= 0, index < documents.count else { return }
        documents.remove(at: index)
        selectedIndex = max(0, min(index, documents.count - 1))
    }
    
    public func selectDocument(at index: Int) {
        guard index >= 0, index < documents.count else { return }
        selectedIndex = index
    }
    
    public func moveDocument(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < documents.count,
              destination >= 0, destination < documents.count else { return }
        let doc = documents.remove(at: source)
        documents.insert(doc, at: destination)
    }
    
    public func closeAll() {
        documents.removeAll()
        selectedIndex = 0
    }

    /// Documents a bulk-close command should prompt for and remove, in tab
    /// order. The caller owns the actual close flow so every document still
    /// goes through the per-document dirty prompt.
    public func documents(matching scope: TabCloseScope) -> [DocumentModel] {
        switch scope {
        case .allButActive, .allButPinned:
            guard let active = selectedDocument else { return [] }
            return documents.filter { $0 !== active }
        case .toLeftOfActive:
            guard selectedIndex > 0 else { return [] }
            return Array(documents[..<selectedIndex])
        case .toRightOfActive:
            guard selectedIndex < documents.count - 1 else { return [] }
            return Array(documents[(selectedIndex + 1)...])
        case .unchanged:
            return documents.filter { !$0.unsavedChanges }
        }
    }
    
    public func toSessionData() -> [[String: Any]] {
        documents.map { $0.toSessionData() }
    }
    
    public static func fromSessionData(_ data: [[String: Any]]) -> TabStore {
        let store = TabStore()
        for item in data {
            if let doc = DocumentModel.fromSessionData(item) {
                store.addDocument(doc)
            }
        }
        return store
    }
}
