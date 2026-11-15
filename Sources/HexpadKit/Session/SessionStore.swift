import Foundation

/// Manages session state persistence
public final class SessionStore {

    /// Test seam: when set, session.json lives here instead of Application Support.
    /// Production code never sets this; tests point it at a temp dir for isolation.
    public static var overrideDirectory: URL?

    /// How long a dirty session waits before the coalesced write runs.
    /// Callers that need a different cadence may pass an explicit delay to
    /// `scheduleSave`, or write immediately with `save`/`flush`.
    public static var debounceInterval: TimeInterval = 2.0

    private static var appSupportDir: URL {
        if let override = overrideDirectory { return override }
        // App-hosted XCTest runs the real app delegate, which now schedules
        // session saves from ordinary document notifications. Without an
        // explicit override those writes must not land in the developer's live
        // session, so tests get a per-process temp directory instead.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("HexpadSessionTestHost-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }
    
    private static var sessionFile: URL {
        appSupportDir.appendingPathComponent("session.json")
    }

    // MARK: - Write Scheduling

    /// All file mutations run on this serial queue. Serialization is what keeps
    /// a debounced write from overlapping an explicit save, and it means the
    /// read-modify-write of session.json can never lose keys to a concurrent
    /// writer.
    private static let queue = DispatchQueue(label: "com.hexpad.session-store")

    private static var pendingWorkItem: DispatchWorkItem?
    private static var pendingTabs: TabStore?
    private static var pendingGeneration: UInt64 = 0
    private static var dirty = false
    private static var lastError: Error?

    /// True while a scheduled write is waiting to run.
    public static var hasPendingChanges: Bool {
        queue.sync { dirty }
    }

    /// The most recent error from a scheduled (non-throwing) flush, if any.
    public static var lastWriteError: Error? {
        queue.sync { lastError }
    }

    /// Mark the session dirty and coalesce writes: rapid change events collapse
    /// into a single write once the debounce interval has elapsed. The latest
    /// store reference wins, so the flush persists the newest state.
    public static func scheduleSave(_ tabs: TabStore, after delay: TimeInterval? = nil) {
        let interval = max(0, delay ?? debounceInterval)
        queue.async {
            pendingTabs = tabs
            dirty = true
            pendingGeneration &+= 1
            let generation = pendingGeneration

            pendingWorkItem?.cancel()
            // The generation check makes a cancelled item a no-op even if
            // dispatch still delivers it after cancellation.
            let item = DispatchWorkItem {
                guard generation == pendingGeneration, dirty else { return }
                do {
                    try flushLocked()
                    lastError = nil
                } catch {
                    lastError = error
                    print("Failed to save session: \(error)")
                }
            }
            pendingWorkItem = item
            queue.asyncAfter(deadline: .now() + interval, execute: item)
        }
    }

    /// Write any pending dirty state now. Explicit save/close paths use this so
    /// quitting never waits for the debounce timer.
    public static func flush() throws {
        try queue.sync {
            try flushLocked()
        }
    }

    /// Drop pending dirty state without writing (e.g. the window was discarded).
    public static func cancelScheduledSave() {
        queue.sync {
            cancelPendingLocked()
        }
    }

    // MARK: - Session State

    /// Save session state immediately, superseding any scheduled write.
    public static func save(_ tabs: TabStore) throws {
        try queue.sync {
            cancelPendingLocked()
            try writeSessionLocked(tabs)
        }
    }
    
    /// Restore session state
    public static func restore() -> (tabs: TabStore, selectedIndex: Int)? {
        queue.sync {
            guard FileManager.default.fileExists(atPath: sessionFile.path) else { return nil }
            
            do {
                let data = try Data(contentsOf: sessionFile)
                guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tabsData = dict["tabs"] as? [[String: Any]],
                      let selectedIndex = dict["selectedIndex"] as? Int else {
                    return nil
                }
                
                let tabs = TabStore.fromSessionData(tabsData)
                return (tabs, selectedIndex)
            } catch {
                print("Failed to restore session: \(error)")
                return nil
            }
        }
    }
    
    /// Clear saved session
    public static func clear() throws {
        try queue.sync {
            cancelPendingLocked()
            try FileManager.default.removeItem(at: sessionFile)
        }
    }
    
    // MARK: - Recent Files
    
    /// Load recent file paths from session.json (most recent first)
    public static func loadRecents() -> [String] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: sessionFile.path) else { return [] }
            do {
                let data = try Data(contentsOf: sessionFile)
                guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recents = dict["recents"] as? [String] else {
                    return []
                }
                return recents
            } catch {
                return []
            }
        }
    }
    
    /// Save recent file paths to session.json (preserving existing tabs/selectedIndex)
    public static func saveRecents(_ paths: [String]) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            
            var data = readExistingLocked()
            data["recents"] = paths
            
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            try writeAtomicallyLocked(jsonData, to: sessionFile)
        }
    }

    // MARK: - Private

    /// Must run on `queue`.
    private static func flushLocked() throws {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil

        guard dirty, let tabs = pendingTabs else { return }
        try writeSessionLocked(tabs)
        dirty = false
        pendingTabs = nil
        lastError = nil
    }

    /// Must run on `queue`.
    private static func cancelPendingLocked() {
        pendingGeneration &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingTabs = nil
        dirty = false
    }

    /// Must run on `queue`.
    private static func writeSessionLocked(_ tabs: TabStore) throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        // Preserve keys written by other writers (e.g. "recents" from saveRecents)
        var data = readExistingLocked()
        data["tabs"] = tabs.toSessionData()
        data["selectedIndex"] = tabs.selectedIndex
        
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try writeAtomicallyLocked(jsonData, to: sessionFile)
    }

    /// Must run on `queue`.
    private static func readExistingLocked() -> [String: Any] {
        guard FileManager.default.fileExists(atPath: sessionFile.path),
              let existing = try? Data(contentsOf: sessionFile),
              let dict = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// Writes `data` to a sibling temp file, then renames it over `url`. A
    /// failure at any point leaves the previous file (or no file) in place and
    /// never exposes a half-written session.json.
    ///
    /// Must run on `queue`.
    private static func writeAtomicallyLocked(_ data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try data.write(to: tempURL)
        try beforeCommit?()

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    /// Test seam: runs after the temp file is complete but before it replaces
    /// the live file. Production never sets this; tests use it for failpoints.
    internal static var beforeCommit: (() throws -> Void)?
}
