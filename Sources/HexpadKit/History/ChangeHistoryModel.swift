import Foundation

/// One row of Notepad++'s Edit > Change History menu.
///
/// A `saved` row carries the exact buffer snapshot taken when the save
/// succeeded; a `modified` row is only a timestamp (there is no buffer to
/// revert to between saves). The row is a value so the app layer can hand it
/// to an `NSMenuItem`'s `representedObject` without looking anything up by
/// index — the menu can be rebuilt at any time and still point at the same
/// entry.
public struct ChangeHistoryEntry: Equatable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case saved
        case modified
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind

    /// Exact text of the buffer at save time. Non-`nil` only for `.saved`.
    public let snapshot: String?

    public init(id: UUID = UUID(),
                timestamp: Date,
                kind: Kind,
                snapshot: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.snapshot = kind == .saved ? snapshot : nil
    }

    public var isSaved: Bool { kind == .saved }

    /// "Saved on <datetime>" / "Modified on <datetime>", as N++ labels them.
    /// A fixed POSIX format keeps the label stable across locales and makes it
    /// testable; the app layer only has to put this string on a menu item.
    public var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let verb = kind == .saved ? "Saved" : "Modified"
        return "\(verb) on \(formatter.string(from: timestamp))"
    }
}

/// Per-document record of save points and edit bursts.
///
/// This is a pure model: callers feed it text snapshots and timestamps, and it
/// hands back entries. It knows nothing about documents, windows or menus, so
/// the coalescing and capping rules can be tested with synthetic timestamps.
///
/// Ordering has two views. ``entries`` is the chronological append order the
/// model maintains internally; ``menuEntries`` is what Edit > Change History
/// displays: saved entries first, then modified entries, each newest first,
/// capped at ``entryLimit``.
public final class ChangeHistoryModel {

    /// Notepad++ shows at most 20 change-history entries. Snapshots are held by
    /// saved entries, so trimming to 20 entries caps snapshots at 20 too.
    public static let entryLimit = 20

    /// Coalescing policy: a run of text changes less than two seconds apart is
    /// ONE "Modified on" entry, not one per keystroke. (Chosen over an
    /// undo-group boundary so the rule stays pure and can be driven with
    /// synthetic timestamps in tests.) A save starts a new burst, since the
    /// saved snapshot is a new baseline.
    public static let coalescingWindow: TimeInterval = 2.0

    /// All recorded entries in the order they were appended (oldest first).
    public private(set) var entries: [ChangeHistoryEntry] = []

    /// ID of the modified entry at the tail of the current edit burst.
    private var activeModificationID: UUID?

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Pure coalescing decision, exposed for tests: two timestamps belong to
    /// the same burst when the later one is within `window` of the earlier.
    /// A backwards or equal-time jump starts a new entry.
    public static func shouldCoalesce(last: Date?,
                                      current: Date,
                                      window: TimeInterval = coalescingWindow) -> Bool {
        guard let last else { return false }
        let delta = current.timeIntervalSince(last)
        return delta > 0 && delta < window
    }

    /// Records any entry. `snapshot` is kept for `.saved` only.
    @discardableResult
    public func record(_ kind: ChangeHistoryEntry.Kind,
                       snapshot: String? = nil,
                       at date: Date = Date()) -> ChangeHistoryEntry {
        switch kind {
        case .saved:
            let entry = ChangeHistoryEntry(timestamp: date, kind: .saved, snapshot: snapshot ?? "")
            entries.append(entry)
            // A saved snapshot is a new baseline: the next edit is its own
            // "Modified on" burst even if it follows a keystroke immediately.
            activeModificationID = nil
        case .modified:
            if let id = activeModificationID,
               let index = entries.firstIndex(where: { $0.id == id }),
               Self.shouldCoalesce(last: entries[index].timestamp, current: date) {
                // Same burst: keep its identity and just move its timestamp
                // forward, so a menu row never multiplies while typing.
                let entry = ChangeHistoryEntry(id: id, timestamp: date, kind: .modified)
                entries[index] = entry
                return entry
            }
            let entry = ChangeHistoryEntry(timestamp: date, kind: .modified)
            entries.append(entry)
            activeModificationID = entry.id
        }
        trimToLimit()
        return entries.last!
    }

    @discardableResult
    public func recordSaved(snapshot: String, at date: Date = Date()) -> ChangeHistoryEntry {
        record(.saved, snapshot: snapshot, at: date)
    }

    @discardableResult
    public func recordModified(at date: Date = Date()) -> ChangeHistoryEntry {
        record(.modified, at: date)
    }

    /// The menu projection: saved rows first, then modified rows, each newest
    /// first, with the total capped at ``entryLimit``.
    public var menuEntries: [ChangeHistoryEntry] {
        let order: (ChangeHistoryEntry, ChangeHistoryEntry) -> Bool = { lhs, rhs in
            lhs.timestamp == rhs.timestamp
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.timestamp > rhs.timestamp
        }
        let saved = entries.filter(\.isSaved).sorted(by: order)
        let modified = entries.filter { !$0.isSaved }.sorted(by: order)
        return Array((saved + modified).prefix(Self.entryLimit))
    }

    /// The exact snapshot of a saved entry, or `nil` if the entry is stale
    /// (trimmed) or is a modified row. Reverting uses this verbatim.
    public func snapshot(for entry: ChangeHistoryEntry) -> String? {
        guard entry.isSaved else { return nil }
        return entries.first { $0.id == entry.id && $0.isSaved }?.snapshot
    }

    /// Drops the oldest entries past the limit and clears a burst whose row
    /// was trimmed away, so a later keystroke cannot resurrect a dead ID.
    private func trimToLimit() {
        guard entries.count > Self.entryLimit else { return }
        entries = Array(entries.suffix(Self.entryLimit))
        if let active = activeModificationID,
           !entries.contains(where: { $0.id == active }) {
            activeModificationID = nil
        }
    }
}
