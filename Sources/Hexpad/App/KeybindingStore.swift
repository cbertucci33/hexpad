import AppKit

extension Notification.Name {
    /// Posted after keybinding overrides are saved, removed, or reset. The app
    /// delegate listens for it and rebuilds the main menu so new key
    /// equivalents take effect immediately.
    static let keybindingsDidChange = Notification.Name("HexpadKeybindingsDidChange")
}

/// A persisted keybinding override for a single command identifier.
struct KeybindingOverride: Codable, Equatable {
    let keyEquivalent: String
    let modifiers: UInt

    var modifierMask: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }
}

/// Reads and writes user keybinding overrides for the editor command registry.
///
/// Overrides live in `Application Support/Hexpad/keybindings.json`, next to
/// `session.json` (see `SessionStore`). The file is a flat JSON object mapping
/// a command identifier to its key equivalent and modifier mask:
///
/// ```json
/// {
///   "duplicate-line": { "keyEquivalent": "j", "modifiers": 1179648 }
/// }
/// ```
///
/// A missing, unreadable, or malformed file simply yields no overrides, so the
/// app always falls back to the defaults in `EditorCommandBindings`.
enum KeybindingStore {

    /// Test seam: when set, keybindings.json lives here instead of Application
    /// Support. Production never sets this; tests point it at a temp dir.
    static var overrideDirectory: URL?

    /// The modifiers we persist (and display). Device-dependent flags such as
    /// caps lock or fn are deliberately dropped.
    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private static var appSupportDir: URL {
        if let override = overrideDirectory { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hexpad")
    }

    static var overridesFileURL: URL {
        appSupportDir.appendingPathComponent("keybindings.json")
    }

    // MARK: - Loading

    /// Loads the override table. Entries that are not well-formed chords are
    /// skipped individually; a file that is not a JSON object yields `[:]`.
    static func loadOverrides() -> [String: KeybindingOverride] {
        guard let data = try? Data(contentsOf: overridesFileURL),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let entries = raw as? [String: Any] else {
            return [:]
        }

        var overrides: [String: KeybindingOverride] = [:]
        for (identifier, value) in entries where !identifier.isEmpty {
            guard let entry = value as? [String: Any],
                  let keyEquivalent = entry["keyEquivalent"] as? String,
                  let modifiers = entry["modifiers"] as? NSNumber else {
                continue
            }
            let mask = NSEvent.ModifierFlags(rawValue: modifiers.uintValue)
                .intersection(allowedModifiers)
            guard isUsable(keyEquivalent: keyEquivalent, modifierMask: mask) else {
                continue
            }
            overrides[identifier] = KeybindingOverride(keyEquivalent: keyEquivalent,
                                                      modifiers: mask.rawValue)
        }
        return overrides
    }

    /// The effective binding for a command: the user's override when present,
    /// otherwise the built-in default.
    static func resolvedBinding(for identifier: String) -> EditorCommandBinding? {
        if let override = loadOverrides()[identifier] {
            return EditorCommandBinding(identifier: identifier,
                                        keyEquivalent: override.keyEquivalent,
                                        modifierMask: override.modifierMask)
        }
        return EditorCommandBinding.binding(for: identifier)
    }

    // MARK: - Saving

    /// Persists one override and posts `.keybindingsDidChange`.
    static func setOverride(_ binding: EditorCommandBinding) throws {
        var overrides = loadOverrides()
        let mask = binding.modifierMask.intersection(allowedModifiers)
        overrides[binding.identifier] = KeybindingOverride(keyEquivalent: binding.keyEquivalent,
                                                           modifiers: mask.rawValue)
        try write(overrides)
        postChange()
    }

    /// Removes one override and posts `.keybindingsDidChange`.
    static func removeOverride(for identifier: String) throws {
        var overrides = loadOverrides()
        overrides.removeValue(forKey: identifier)
        try write(overrides)
        postChange()
    }

    /// Deletes the override file, restoring every default. Posts
    /// `.keybindingsDidChange`.
    static func resetToDefaults() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: overridesFileURL.path) {
            try fileManager.removeItem(at: overridesFileURL)
        }
        postChange()
    }

    private static func write(_ overrides: [String: KeybindingOverride]) throws {
        try FileManager.default.createDirectory(at: appSupportDir,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(overrides)
        try data.write(to: overridesFileURL, options: .atomic)
    }

    private static func postChange() {
        NotificationCenter.default.post(name: .keybindingsDidChange, object: nil)
    }

    // MARK: - Chord helpers

    /// Rejects chords that would intercept ordinary typing or navigation: an
    /// empty key, or one with only Shift held (Shift alone is not a menu
    /// modifier on macOS). Bare function keys (F1–F12 and friends, which live
    /// in the private-use unicode area) are exempt: they never produce printable
    /// characters, so they can be captured and bound without a modifier.
    static func isUsable(keyEquivalent: String, modifierMask: NSEvent.ModifierFlags) -> Bool {
        guard !keyEquivalent.isEmpty else { return false }
        if modifierMask.isEmpty, isFunctionKey(keyEquivalent) {
            return true
        }
        return !modifierMask.intersection([.command, .option, .control]).isEmpty
    }

    /// Function keys F1–F12 arrive as private-use unicode scalars (F2 is
    /// "\u{F705}", F5 is "\u{F708}"), so they never collide with ordinary text.
    static func isFunctionKey(_ keyEquivalent: String) -> Bool {
        guard keyEquivalent.unicodeScalars.count == 1,
              let scalar = keyEquivalent.unicodeScalars.first else { return false }
        return scalar.value >= 0xF704 && scalar.value <= 0xF70F
    }

    /// Turns a key-down event into the `(keyEquivalent, modifierMask)` pair a
    /// menu item expects. Returns `nil` for modifier-less keys, which the
    /// capture UI treats as an invalid chord.
    static func keyChord(from event: NSEvent) -> (keyEquivalent: String, modifierMask: NSEvent.ModifierFlags)? {
        let mask = event.modifierFlags.intersection(allowedModifiers)
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        // Shift is carried by the mask, so store the unshifted character.
        let key = characters.lowercased()
        guard isUsable(keyEquivalent: key, modifierMask: mask) else { return nil }
        return (key, mask)
    }

    /// Menu-friendly rendering: ⌃⌥⇧⌘ order, arrow glyphs for AppKit's
    /// private-use function-key scalars, uppercase for everything else.
    static func displayString(for binding: EditorCommandBinding?) -> String {
        guard let binding else { return "None" }

        var result = ""
        if binding.modifierMask.contains(.control) { result += "⌃" }
        if binding.modifierMask.contains(.option) { result += "⌥" }
        if binding.modifierMask.contains(.shift) { result += "⇧" }
        if binding.modifierMask.contains(.command) { result += "⌘" }

        switch binding.keyEquivalent {
        case EditorCommandBinding.upArrow: result += "↑"
        case EditorCommandBinding.downArrow: result += "↓"
        case EditorCommandBinding.f2: result += "F2"
        case "\u{F702}": result += "←"
        case "\u{F703}": result += "→"
        case " ": result += "Space"
        case "\t": result += "Tab"
        default: result += binding.keyEquivalent.uppercased()
        }
        return result
    }
}
