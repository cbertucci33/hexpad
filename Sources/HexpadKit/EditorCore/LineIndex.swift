import Foundation

/// Precomputed line-start offsets for a text, answering the same questions as
/// ``GutterGeometry`` in O(log n) instead of one full scan per call.
///
/// `GutterGeometry.logicalLine(of:in:)` and `firstCharIndex(of:in:)` are the
/// app's agreed source of truth for line math, so this index deliberately
/// reproduces their exact conventions rather than re-inventing them:
///
/// - Only LF (`\u{0A}`) starts a new logical line. The editor buffer is LF-only
///   by construction (CRLF/CR are converted to LF on open and back on save),
///   and `GutterGeometry` counts LF only, so a stray `\r` is an ordinary
///   character on its current line. Both implementations therefore agree on
///   positions inside a `\r\n` pair.
/// - Offsets are UTF-16 code units, matching `NSRange` and `NSTextView`.
/// - Line numbers are 1-based. A trailing LF opens a final empty line, so
///   `count` equals `GutterGeometry.lineCount(in:)`.
/// - Out-of-range input clamps like `GutterGeometry` does: caret positions
///   past the end map to the last line, line numbers past the end map to the
///   text length.
///
/// The index is immutable. When the text changes, build a new index; that is
/// what lets callers cache one per text generation and keep caret moves free
/// of document scans.
public struct LineIndex: Sendable {

    /// `lineStarts[i]` is the UTF-16 offset at which the (i + 1)-th logical
    /// line begins. Sorted ascending, starts with 0, and contains exactly one
    /// entry per logical line (including the empty line after a trailing LF).
    public let lineStarts: [Int]

    /// Length of the indexed text in UTF-16 code units, i.e. the coordinate
    /// space of `line(of:)` and `firstCharIndex(of:)`.
    public let textLength: Int

    /// Number of logical lines, the equivalent of
    /// `GutterGeometry.lineCount(in:)`.
    public var count: Int { lineStarts.count }

    /// Diagnostic for the incremental path: how many line starts the last
    /// `updating(...)` scan had to regenerate. A full `init` leaves this at 0.
    public private(set) var lastUpdateScannedLineCount = 0

    /// Builds the index in a single pass over the text's UTF-16 code units.
    public init(_ text: String) {
        var starts: [Int] = [0]
        starts.reserveCapacity(32)
        var length = 0

        // The contiguous fast path avoids per-unit iterator overhead for the
        // common case (the whole buffer is already contiguous in memory).
        let usedFastPath = text.utf16.withContiguousStorageIfAvailable { buffer -> Bool in
            length = buffer.count
            for offset in 0..<buffer.count where buffer[offset] == 0x0A {
                starts.append(offset + 1)
            }
            return true
        } ?? false

        if !usedFastPath {
            for unit in text.utf16 {
                if unit == 0x0A {
                    starts.append(length + 1)
                }
                length += 1
            }
        }

        self.textLength = length
        self.lineStarts = starts
    }

    /// Private init used by the incremental path.
    private init(lineStarts: [Int], textLength: Int, scannedLines: Int) {
        self.lineStarts = lineStarts
        self.textLength = textLength
        self.lastUpdateScannedLineCount = scannedLines
    }

    /// Returns a new index for `text` after one `NSTextStorage` edit.
    ///
    /// `editedRange` is the post-edit range (the same value the container and
    /// highlighter receive) and `changeInLength` is `storage.changeInLength`.
    /// Only the line starts touched by the edit are regenerated: the prefix is
    /// copied, the band between the edited line and the old suffix is rescanned
    /// in the new text, and the unchanged suffix is shifted by the edit delta.
    /// Any inconsistent range or length falls back to a full scan, so a stale
    /// edit can never corrupt the index.
    public func updating(_ text: String,
                         editedRange: NSRange,
                         changeInLength: Int) -> LineIndex {
        let nsText = text as NSString
        let newLength = nsText.length
        guard newLength == textLength + changeInLength,
              editedRange.location >= 0,
              editedRange.length >= 0,
              editedRange.location <= newLength,
              editedRange.length <= newLength - editedRange.location else {
            return LineIndex(text)
        }

        let insertedLength = editedRange.length
        let replacedLength = max(0, insertedLength - changeInLength)
        let location = min(max(0, editedRange.location), textLength)
        let oldSuffixStart = min(location + replacedLength, textLength)

        let oldFirstLine = indexOfLastStart(atOrBefore: location)
        let oldResume = indexOfFirstStart(after: oldSuffixStart)
        let newBandStart = lineStarts[oldFirstLine]
        let newSuffixStart = location + insertedLength

        // Rescan only the post-edit band, from the start of the first affected
        // line through the character before the unchanged suffix.
        var bandStarts: [Int] = [newBandStart]
        let bandLength = max(0, newSuffixStart - newBandStart)
        let bandText = nsText.substring(with: NSRange(location: newBandStart, length: bandLength))
        var offset = newBandStart
        for unit in bandText.utf16 {
            if unit == 0x0A {
                bandStarts.append(offset + 1)
            }
            offset += 1
        }

        let prefix = Array(lineStarts[0..<oldFirstLine])
        let suffix = lineStarts[oldResume...].map { $0 + changeInLength }
        var starts = prefix
        starts.reserveCapacity(prefix.count + bandStarts.count + suffix.count)
        starts.append(contentsOf: bandStarts)
        starts.append(contentsOf: suffix)

        return LineIndex(lineStarts: starts,
                         textLength: newLength,
                         scannedLines: bandStarts.count)
    }

    /// Index of the last line start at or before `offset`.
    private func indexOfLastStart(atOrBefore offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        var result = 0
        while low <= high {
            let mid = low + (high - low) / 2
            if lineStarts[mid] <= offset {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Index of the first line start strictly after `offset`.
    private func indexOfFirstStart(after offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = low + (high - low) / 2
            if lineStarts[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// 1-based logical line number containing `charIndex`, a UTF-16 offset.
    ///
    /// Equivalent to `GutterGeometry.logicalLine(of:in:)`: a caret at offset 0
    /// is on line 1, and the line changes only once the caret is past an LF.
    public func line(of charIndex: Int) -> Int {
        guard charIndex > 0 else { return 1 }
        // GutterGeometry clamps the scan to the text length, so positions past
        // the end resolve to the last line.
        return upperBound(of: min(charIndex, textLength))
    }

    /// First UTF-16 offset of a 1-based logical line.
    ///
    /// Equivalent to `GutterGeometry.firstCharIndex(of:in:)`: line 1 starts at
    /// 0, and line numbers past the end clamp to the text length.
    public func firstCharIndex(of line: Int) -> Int {
        guard line > 1 else { return 0 }
        guard line <= lineStarts.count else { return textLength }
        return lineStarts[line - 1]
    }

    /// Number of line starts at or before `offset`. This is exactly the number
    /// of LFs strictly before `offset`, plus one, so it is also the 1-based
    /// line holding that offset.
    private func upperBound(of offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = low + (high - low) / 2
            if lineStarts[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
