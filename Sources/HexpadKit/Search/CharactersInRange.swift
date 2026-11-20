import Foundation
import HexpadKit

/// Wave 6, docs review item 27 second half: N++ Search > "Find characters in
/// range…" takes a range like 20-300 and selects every character whose
/// Unicode code point falls inside it. The pure Kit half lives here: parse
/// the range spec, locate matches. The dialog + selection wiring live in the
/// app target (FindCharactersInRangeWindowController).
public enum CharactersInRange {

    public enum ParseError: Error, Equatable {
        /// Not "low-high" or a single number.
        case malformed
        /// Low bound greater than high.
        case inverted
        /// Bounds outside Unicode's scalar space.
        case outOfRange
    }

    /// Parses "20-300" (inclusive both ends) or "65" (a single scalar).
    /// Accepts decimal only; whitespace around numbers and the dash is fine.
    public static func parse(_ spec: String) -> Result<ClosedRange<UInt32>, ParseError> {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.malformed) }
        let parts = trimmed.components(separatedBy: "-")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let lowText: String
        let highText: String
        if parts.count == 1 {
            lowText = parts[0]
            highText = parts[0]
        } else if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            lowText = parts[0]
            highText = parts[1]
        } else {
            return .failure(.malformed)
        }
        guard let low = UInt32(lowText), let high = UInt32(highText) else {
            return .failure(.malformed)
        }
        guard low <= high else { return .failure(.inverted) }
        guard high <= 0x10FFFF else { return .failure(.outOfRange) }
        return .success(low...high)
    }

    /// Every range in `text` whose code point falls in `range`. Each Unicode
    /// scalar is one match (composed characters may yield several adjacent
    /// matches, which is correct: N++ matches code points too).
    public static func matches(in text: String, range: ClosedRange<UInt32>) -> [NSRange] {
        var result: [NSRange] = []
        var location = 0
        for scalar in text.unicodeScalars {
            let length = String(scalar).utf16.count
            if range.contains(scalar.value) {
                result.append(NSRange(location: location, length: length))
            }
            location += length
        }
        return result
    }

    /// Parse + locate in one call for the dialog's OK path.
    public static func matches(in text: String, spec: String) -> Result<[NSRange], ParseError> {
        switch parse(spec) {
        case .success(let range):
            return .success(matches(in: text, range: range))
        case .failure(let error):
            return .failure(error)
        }
    }
}
