import Foundation
import HexpadKit

/// Manages the list of recently opened files and the File > Open Recent submenu.
///
/// Ratified semantic (CB): record on OPEN (matches macOS Open Recent convention).
/// The list keeps open + recently-opened files, most-recent-first, capped at
/// `recentFilesMax`. It is NOT restricted to closed files — macOS shows open
/// files in Open Recent too. `mostRecentClosedFile(openPaths:)` is the only
/// place that filters out currently-open paths, and only for the
/// Restore Recent Closed File command.
final class RecentFilesManager: NSObject {
    
    /// Notification posted when the recents list changes; menu rebuilds in response.
    static let didChange = Notification.Name("RecentFilesDidChange")
    
    private(set) var recents: [String] = []
    
    override init() {
        super.init()
        recents = Self.trimmed(SessionStore.loadRecents())
    }
    
    /// Add a file path to recents. Moves existing entry to top, no dupes, capped
    /// at the Settings > Advanced `recentFilesMax` value (default 10; 0 empties
    /// the list).
    func addRecent(_ path: String) {
        guard !path.isEmpty else { return }
        var updated = recents.filter { $0 != path }
        updated.insert(path, at: 0)
        updated = Self.trimmed(updated)
        recents = updated
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    
    /// The newest recent entry that is not currently open.
    ///
    /// This manager keeps a single newest-first list of every file opened; it
    /// does not track closed files separately. "Most recent closed" therefore
    /// means the newest entry whose path is not among `openPaths` — the caller
    /// supplies the paths its tabs currently hold. Callers without open-file
    /// knowledge can omit the argument and get the newest entry.
    func mostRecentClosedFile(openPaths: Set<String> = []) -> URL? {
        guard let path = recents.first(where: { !openPaths.contains($0) }) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Empty the list (File > Empty Recent Files List).
    func removeAll() {
        guard !recents.isEmpty else { return }
        recents = []
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
        updated = Self.trimmed(updated)
        recents = updated
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    
    /// The live cap from Settings. `Preferences.normalized()` already clamps the
    /// value, but the store is re-read here so a change applies without
    /// relaunching.
    private static func trimmed(_ paths: [String]) -> [String] {
        let limit = PreferencesStore.load().recentFilesMax
        let clamped = min(max(limit, Preferences.recentFilesMaxRange.lowerBound),
                          Preferences.recentFilesMaxRange.upperBound)
        return Array(paths.prefix(clamped))
    }
    
    private func persist() {
        try? SessionStore.saveRecents(recents)
    }
}
