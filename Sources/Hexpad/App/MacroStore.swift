import Foundation
import HexpadKit

/// Reads and writes the user's saved editor macros.
///
/// Macros live in `Application Support/Hexpad/macros.json`, next to
/// `session.json` (see `SessionStore`) and `keybindings.json` (see
/// `KeybindingStore`). The file is a JSON array of ``MacroModel`` values:
///
/// ```json
/// [
///   {
///     "name": "Sort and duplicate",
///     "steps": [{ "identifier": "duplicate-line" }]
///   }
/// ]
/// ```
///
/// A missing, unreadable, or malformed file simply yields no macros, and an
/// individually malformed entry is skipped, so the app always starts with the
/// macros it can actually replay instead of failing to load at all. The
/// transient `isRecording` flag is not encoded by ``MacroModel``, so a loaded
/// macro is never recording.
enum MacroStore {

    /// Test seam: when set, macros.json lives here instead of Application
    /// Support. Production never sets this; tests point it at a temp dir.
    static var overrideDirectory: URL?

    private static var appSupportDir: URL {
        if let override = overrideDirectory { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }

    static var macrosFileURL: URL {
        appSupportDir.appendingPathComponent("macros.json")
    }

    // MARK: - Loading

    /// Loads every well-formed saved macro, in file order.
    ///
    /// Entries are decoded one at a time so a single corrupt record cannot
    /// discard the rest of the file. Anything that is not a JSON array (or an
    /// entry that is not a macro object) is ignored.
    static func load() -> [MacroModel] {
        guard let data = try? Data(contentsOf: macrosFileURL),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let entries = raw as? [Any] else {
            return []
        }

        let decoder = JSONDecoder()
        var macros: [MacroModel] = []
        for entry in entries {
            // `data(withJSONObject:)` raises (not throws) on non-container
            // values such as a bare string, so screen them out first.
            guard JSONSerialization.isValidJSONObject(entry),
                  let entryData = try? JSONSerialization.data(withJSONObject: entry),
                  let macro = try? decoder.decode(MacroModel.self, from: entryData),
                  !macro.name.isEmpty,
                  !containsMacro(named: macro.name, in: macros) else {
                continue
            }
            macros.append(macro)
        }
        return macros
    }

    /// The saved macro with this exact name, or `nil` when none is saved.
    static func macro(named name: String) -> MacroModel? {
        load().first { $0.name == name }
    }

    // MARK: - Saving

    /// Inserts or replaces the macro with the same name and returns the new
    /// saved list.
    ///
    /// A recording is never persisted as "recording": ``MacroModel`` encodes
    /// only its name and steps.
    @discardableResult
    static func set(_ macro: MacroModel) throws -> [MacroModel] {
        var macros = load().filter { $0.name != macro.name }
        macros.append(macro)
        try write(macros)
        return macros
    }

    /// Removes the macro with this name and returns the remaining saved list.
    @discardableResult
    static func remove(named name: String) throws -> [MacroModel] {
        let macros = load().filter { $0.name != name }
        try write(macros)
        return macros
    }

    /// Replaces the whole saved list, used by tests and future bulk edits.
    static func save(_ macros: [MacroModel]) throws {
        try write(macros)
    }

    private static func write(_ macros: [MacroModel]) throws {
        try FileManager.default.createDirectory(at: appSupportDir,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(macros)
        try data.write(to: macrosFileURL, options: .atomic)
    }

    private static func containsMacro(named name: String, in macros: [MacroModel]) -> Bool {
        macros.contains { $0.name == name }
    }
}
