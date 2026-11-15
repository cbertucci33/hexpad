import Foundation

// MARK: - Session persistence

extension FoldState {

    /// JSON-ready projection of the collapsed folds, nested under a single
    /// `foldState` key in the document's session dictionary.
    ///
    /// The projection stores only UTF-16 ranges and kind strings, not text, so
    /// its shape is independent of the document's contents. Restoring a state
    /// whose offsets no longer match the text is the app layer's concern: the
    /// ranges are carried verbatim and `FoldModel`/`FoldVisibility` decide what
    /// is still usable against the current document.
    ///
    /// Entries are sorted by location, then length, then kind so repeated
    /// saves of the same state produce byte-identical session data.
    func toSessionData() -> [String: Any] {
        let folds: [[String: Any]] = collapsedRanges
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                if lhs.range.length != rhs.range.length {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            .map { fold in
                [
                    "location": fold.range.location,
                    "length": fold.range.length,
                    "kind": fold.kind.rawValue
                ]
            }
        return ["collapsedRanges": folds]
    }

    /// Restores a state written by ``toSessionData()``.
    ///
    /// A session written before fold persistence existed has no `foldState` key
    /// and restores as an empty state. Malformed entries are skipped
    /// individually rather than discarding the whole state, and an unrecognised
    /// kind (from a newer build) is ignored the same way.
    static func fromSessionData(_ data: [String: Any]?) -> FoldState {
        guard let data,
              let entries = data["collapsedRanges"] as? [[String: Any]] else {
            return FoldState()
        }

        var state = FoldState()
        for entry in entries {
            guard let location = intValue(entry["location"]), location >= 0,
                  let length = intValue(entry["length"]), length > 0,
                  let kindName = entry["kind"] as? String,
                  let kind = FoldRange.Kind(rawValue: kindName) else {
                continue
            }
            state.insert(FoldRange(location: location, length: length, kind: kind))
        }
        return state
    }

    // JSONSerialization hands numbers back as NSNumber; tests and callers may
    // also supply native Swift numbers. Accept both.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}
