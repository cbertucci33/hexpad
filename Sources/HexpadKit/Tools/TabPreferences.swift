import Foundation

/// Display helpers for the tab bar.
public enum TabLabel {

    /// Truncates a tab caption to the user's maximum label length.
    ///
    /// `maxLength <= 0` means unlimited and returns `name` unchanged. Otherwise
    /// the result contains at most `maxLength` characters, ending in a single
    /// ellipsis when anything was cut, so `"report.txt"` with a limit of 5
    /// becomes `"repo…"`. Counting is by extended grapheme cluster (Swift
    /// `Character`), matching what the label displays, not by UTF-16 units.
    public static func truncated(_ name: String, maxLength: Int) -> String {
        guard maxLength > 0, name.count > maxLength else { return name }
        guard maxLength > 1 else { return "…" }
        return String(name.prefix(maxLength - 1)) + "…"
    }
}

/// A most-recently-used order over arbitrary hashable elements.
///
/// The newest element is first. The editor keeps one of these per window to
/// implement Notepad++'s MRU tab switching: activation touches a document id,
/// and `next`/`previous` return the neighbors in usage order instead of the
/// positional tab order. Elements that are not present are ignored by `touch`,
/// and `synchronize(with:)` prunes closed elements and appends new ones in the
/// caller's order (positional) so a freshly opened tab still participates.
public struct MRUOrder<Element: Hashable>: Equatable {

    /// Most recently used first.
    public private(set) var items: [Element]

    public init(items: [Element] = []) {
        self.items = []
        for item in items where !self.items.contains(item) {
            self.items.append(item)
        }
    }

    /// Marks `item` as the most recently used, moving it to the front.
    public mutating func touch(_ item: Element) {
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
    }

    /// Keeps only `elements`, in the current MRU order, then appends any new
    /// elements in the caller's order.
    public mutating func synchronize(with elements: [Element]) {
        let known = Set(elements)
        items = items.filter { known.contains($0) }
        for element in elements where !items.contains(element) {
            items.append(element)
        }
    }

    /// The next-older element after `item`, wrapping to the newest.
    ///
    /// Returns the first element when `item` is absent, and `nil` when the list
    /// has no other element than `item`.
    public func next(after item: Element) -> Element? {
        guard let index = items.firstIndex(of: item) else { return items.first }
        guard items.count > 1 else { return nil }
        return items[(index + 1) % items.count]
    }

    /// The next-newer element before `item`, wrapping to the oldest.
    ///
    /// Returns the first element when `item` is absent, and `nil` when the list
    /// has no other element than `item`.
    public func previous(after item: Element) -> Element? {
        guard let index = items.firstIndex(of: item) else { return items.first }
        guard items.count > 1 else { return nil }
        return items[(index - 1 + items.count) % items.count]
    }
}
