import Foundation

/// Detectives the line-ending style of a document from its text or raw bytes.
///
/// The style names match `DocumentModel.eolType` and the values persisted in
/// sessions: `"CRLF"`, `"LF"` and `"CR"`.
public final class EOLDetective {

    /// Name reported for Windows-style line endings (`\r\n`).
    public static let crlf = "CRLF"

    /// Name reported for Unix-style line endings (`\n`).
    public static let lf = "LF"

    /// Name reported for classic Mac-style line endings (`\r`).
    public static let cr = "CR"

    /// Name reported when a caller explicitly asks for mixed line endings.
    /// Detection itself reports the dominant style instead of this value.
    public static let mixed = "Mixed"

    // MARK: - Detection

    /// Detects the line-ending style of `text`.
    ///
    /// A file with a single style reports that style. A mixed file reports its
    /// dominant style, with ties going to the style that appears first. Text
    /// without any line terminator (including the empty string) reports `"LF"`
    /// as the conventional default.
    public static func detect(_ text: String) -> String {
        counts(in: text).dominant
    }

    /// Detects the line-ending style of raw file bytes.
    ///
    /// The bytes are decoded with the encoding `EncodingDetective` reports, so
    /// multi-byte UTF-8 sequences cannot be mistaken for line terminators.
    public static func detect(_ data: Data) -> String {
        detect(decodedText(from: data))
    }

    /// Returns true when `text` contains more than one line-ending style.
    public static func isMixed(_ text: String) -> Bool {
        counts(in: text).isMixed
    }

    /// Returns true when the decoded `data` contains more than one line-ending
    /// style.
    public static func isMixed(_ data: Data) -> Bool {
        isMixed(decodedText(from: data))
    }

    // MARK: - Conversion

    /// Rewrites every line ending in `text` to `eolType` (`"CRLF"`, `"LF"` or
    /// `"CR"`). Unknown styles are treated as `"LF"`.
    ///
    /// This normalizes through LF first, so converting is idempotent and never
    /// turns CRLF into two line endings.
    public static func converting(_ text: String, to eolType: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        switch eolType.uppercased() {
        case "CRLF":
            return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case "CR":
            return normalized.replacingOccurrences(of: "\n", with: "\r")
        default:
            return normalized
        }
    }

    // MARK: - Internals

    /// Counts each line-ending style in one pass. CRLF is consumed as a single
    /// terminator so it is not also counted as a lone CR and LF.
    private static func counts(in text: String) -> EOLCounts {
        var result = EOLCounts()
        let utf8 = text.utf8
        var index = utf8.startIndex

        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0D {
                let next = utf8.index(after: index)
                if next < utf8.endIndex, utf8[next] == 0x0A {
                    result.crlf += 1
                    result.record(crlf)
                    index = utf8.index(after: next)
                    continue
                }
                result.cr += 1
                result.record(cr)
                index = next
                continue
            }
            if byte == 0x0A {
                result.lf += 1
                result.record(lf)
            }
            index = utf8.index(after: index)
        }
        return result
    }

    /// Decodes raw bytes with the detected encoding, falling back to a lossy
    /// UTF-8 decode. Both paths preserve ASCII CR/LF bytes exactly.
    private static func decodedText(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let name = EncodingDetective.detect(data)
        let encoding = String.Encoding(rawValue: EncodingDetective.nsEncoding(from: name))
        return String(data: data, encoding: encoding)
            ?? String(decoding: data, as: UTF8.self)
    }

    private struct EOLCounts {
        var crlf = 0
        var lf = 0
        var cr = 0

        /// The first style encountered, used to break ties.
        var first: String?

        var isMixed: Bool {
            [crlf, lf, cr].filter { $0 > 0 }.count > 1
        }

        var dominant: String {
            guard first != nil else { return EOLDetective.lf }
            let highest = max(crlf, max(lf, cr))
            if let first, count(of: first) == highest { return first }
            if crlf == highest { return EOLDetective.crlf }
            if lf == highest { return EOLDetective.lf }
            return EOLDetective.cr
        }

        mutating func record(_ style: String) {
            if first == nil { first = style }
        }

        func count(of style: String) -> Int {
            switch style {
            case EOLDetective.crlf: return crlf
            case EOLDetective.cr: return cr
            default: return lf
            }
        }
    }
}
