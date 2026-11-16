import Foundation

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
