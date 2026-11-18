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

/// The key used by Window > Sort By. Raw values match the menu items'
/// `representedObject`, so one action can decode all ten sort commands.
/// Tab order is window chrome: sorting never touches the undo stack or a
/// document's saved payload.
public enum TabSortKey: String {
    case name, path, type, length, modified
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

    /// Reorders `documents` in place by `key`. Swift's `sorted(by:)` is stable,
    /// so documents with an equal key keep their existing relative tab order.
    /// A missing path/extension/modification date always sorts last in *both*
    /// directions, so untitled and never-saved tabs never jump to the top when
    /// the order is reversed.
    ///
    /// The selected document is followed to its new index. Like
    /// `MainWindowController.moveSelectedTab`, this is window chrome only: no
    /// undo interaction and no change to a document's saved payload.
    public func sortDocuments(by key: TabSortKey, ascending: Bool) {
        guard documents.count > 1 else { return }
        let selected = selectedDocument

        /// Nil always sorts last regardless of direction; equal values keep
        /// their original order so the sort stays stable.
        func orderedBefore<T>(_ a: T?, _ b: T?, ascending: Bool,
                              compare: (T, T) -> ComparisonResult) -> Bool {
            switch (a, b) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (lhs?, rhs?):
                let result = compare(lhs, rhs)
                if result == .orderedSame { return false }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }

        func nonEmpty(_ value: String?) -> String? {
            value.flatMap { $0.isEmpty ? nil : $0 }
        }

        documents = documents.sorted { lhs, rhs in
            switch key {
            case .name:
                let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if result == .orderedSame { return false }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            case .path:
                return orderedBefore(nonEmpty(lhs.filePath?.path),
                                     nonEmpty(rhs.filePath?.path),
                                     ascending: ascending) {
                    $0.localizedCaseInsensitiveCompare($1)
                }
            case .type:
                return orderedBefore(nonEmpty(lhs.filePath?.pathExtension.lowercased()),
                                     nonEmpty(rhs.filePath?.pathExtension.lowercased()),
                                     ascending: ascending) {
                    $0.localizedCaseInsensitiveCompare($1)
                }
            case .length:
                let left = lhs.textStorage.length
                let right = rhs.textStorage.length
                if left == right { return false }
                return ascending ? left < right : left > right
            case .modified:
                return orderedBefore(savedModificationDate(for: lhs),
                                     savedModificationDate(for: rhs),
                                     ascending: ascending) { $0.compare($1) }
            }
        }

        if let selected, let newIndex = documents.firstIndex(where: { $0 === selected }) {
            selectedIndex = newIndex
        } else {
            // No valid selection before the sort (empty store or stale index).
            selectedIndex = 0
        }
    }

    /// - Parameter document: A document with a saved file; untitled and
    /// never-saved documents yield nil and sort last.
    private func savedModificationDate(for document: DocumentModel) -> Date? {
        if let saved = document.savedModificationDate { return saved }
        guard let path = document.filePath?.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.modificationDate] as? Date
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
