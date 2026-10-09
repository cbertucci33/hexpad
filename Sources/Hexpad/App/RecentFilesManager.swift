import Foundation
import HexpadKit

/// Manages the list of recently opened files and the File > Open Recent submenu.
final class RecentFilesManager: NSObject {
    
    static let maxRecents = 10
    
    /// Notification posted when the recents list changes; menu rebuilds in response.
    static let didChange = Notification.Name("RecentFilesDidChange")
    
    private(set) var recents: [String] = []
    
    override init() {
        super.init()
        recents = SessionStore.loadRecents()
    }
    
    /// Add a file path to recents. Moves existing entry to top, no dupes, capped at maxRecents.
    func addRecent(_ path: String) {
        guard !path.isEmpty else { return }
        var updated = recents.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > Self.maxRecents {
            updated = Array(updated.prefix(Self.maxRecents))
        }
        recents = updated
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    
    /// Replace an old path with a new one (used on Save As).
    func replaceRecent(oldPath: String?, newPath: String) {
        guard !newPath.isEmpty else { return }
        if let oldPath {
            recents = recents.filter { $0 != oldPath }
        }
        var updated = recents.filter { $0 != newPath }
        updated.insert(newPath, at: 0)
        if updated.count > Self.maxRecents {
            updated = Array(updated.prefix(Self.maxRecents))
        }
        recents = updated
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    
    private func persist() {
        try? SessionStore.saveRecents(recents)
    }
}
