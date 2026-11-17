import Foundation

/// Pure column math for whitespace rendering (space dots, tab arrows, and
/// indent guides). Lives in HexpadKit so the tab-stop rules are testable
/// without AppKit; the app maps columns to points from the live layout.
public enum WhitespaceGeometry {

    /// One leading-whitespace character's span in tab-stop columns. A space is
    /// one column wide; a tab runs to the next multiple of `tabSize`.
    public struct ColumnRun: Equatable {
        public let startColumn: Int
        public let endColumn: Int

        public init(startColumn: Int, endColumn: Int) {
            self.startColumn = startColumn
            self.endColumn = endColumn
        }
    }

    /// Column spans for each character of `whitespace`, in visual order.
    ///
    /// Non-whitespace characters are ignored, so callers can pass an
    /// indentation prefix or the whole line with the same result. `tabSize` is
    /// clamped to at least 1.
    public static func columnRuns(forLeadingWhitespace whitespace: String,
                                  tabSize: Int) -> [ColumnRun] {
        let tab = max(1, tabSize)
        var column = 0
        var runs: [ColumnRun] = []
        for character in whitespace {
            switch character {
            case " ":
                runs.append(ColumnRun(startColumn: column, endColumn: column + 1))
                column += 1
            case "\t":
                let end = ((column / tab) + 1) * tab
                runs.append(ColumnRun(startColumn: column, endColumn: end))
                column = end
            default:
                continue
            }
        }
        return runs
    }

    /// Total visual width of a leading-whitespace string in tab-stop columns.
    public static func indentationColumns(forLeadingWhitespace whitespace: String,
                                          tabSize: Int) -> Int {
        columnRuns(forLeadingWhitespace: whitespace, tabSize: tabSize).last?.endColumn ?? 0
    }

    /// Columns that draw an indent guide: every tab stop strictly after the
    /// first one, up to and including the indentation width.
    ///
    /// A line indented by one stop or less gets no guide, matching Notepad++
    /// (the first stop is the line's own indentation, not a guide).
    public static func guideColumns(forLeadingWhitespace whitespace: String,
                                    tabSize: Int) -> [Int] {
        let tab = max(1, tabSize)
        let total = indentationColumns(forLeadingWhitespace: whitespace, tabSize: tab)
        guard total >= tab else { return [] }
        return Array(stride(from: tab, through: total, by: tab))
    }
}
