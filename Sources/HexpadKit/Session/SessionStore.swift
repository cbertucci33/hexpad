import Foundation

/// Manages session state persistence
public final class SessionStore {

    /// Test seam: when set, session.json lives here instead of Application Support.
    /// Production code never sets this; tests point it at a temp dir for isolation.
    public static var overrideDirectory: URL?

    private static var appSupportDir: URL {
        if let override = overrideDirectory { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }
    
    private static var sessionFile: URL {
        appSupportDir.appendingPathComponent("session.json")
    }
    
    /// Save session state
    public static func save(_ tabs: TabStore) throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        // Preserve keys written by other writers (e.g. "recents" from saveRecents)
        var data: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: sessionFile.path) {
            if let existing = try? Data(contentsOf: sessionFile),
               let dict = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] {
                data = dict
            }
        }
        data["tabs"] = tabs.toSessionData()
        data["selectedIndex"] = tabs.selectedIndex
        
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try jsonData.write(to: sessionFile)
    }
    
    /// Restore session state
    public static func restore() -> (tabs: TabStore, selectedIndex: Int)? {
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
    
    /// Clear saved session
    public static func clear() throws {
        try FileManager.default.removeItem(at: sessionFile)
    }
    
    // MARK: - Recent Files
    
    /// Load recent file paths from session.json (most recent first)
    public static func loadRecents() -> [String] {
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
    
    /// Save recent file paths to session.json (preserving existing tabs/selectedIndex)
    public static func saveRecents(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        var data: [String: Any] = [:]
        
        // Preserve existing session data if file exists
        if FileManager.default.fileExists(atPath: sessionFile.path) {
            do {
                let existing = try Data(contentsOf: sessionFile)
                data = try JSONSerialization.jsonObject(with: existing) as? [String: Any] ?? [:]
            } catch {
                data = [:]
            }
        }
        
        data["recents"] = paths
        
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try jsonData.write(to: sessionFile)
    }
}
