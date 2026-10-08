import Foundation

/// Manages session state persistence
public final class SessionStore {
    
    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }
    
    private static var sessionFile: URL {
        appSupportDir.appendingPathComponent("session.json")
    }
    
    /// Save session state
    public static func save(_ tabs: TabStore) throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        var data: [String: Any] = [
            "tabs": tabs.toSessionData(),
            "selectedIndex": tabs.selectedIndex
        ]
        
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
}
