import Foundation

/// Notepad++ "Extended" search-mode escapes.
///
/// Extended mode is a literal search whose query first has a small set of
/// backslash escapes expanded. It is deliberately not a regex dialect: the
/// translated string is handed to `SearchEngine` with `.regex` off, so
/// characters such as `.` or `*` keep their literal meaning.
public enum ExtendedSearch {

    /// Expands `\n`, `\r`, `\t`, `\0`, `\xHH` and `\\` and leaves every other
    /// backslash sequence exactly as typed. Preserving unknown escapes keeps a
    /// Windows path or a regex-looking query searchable without surprises.
    public static func translate(_ pattern: String) -> String {
        guard pattern.contains("\\") else { return pattern }

        let characters = Array(pattern)
        var result = String()
        result.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }

            // A trailing backslash has nothing to escape.
            guard index + 1 < characters.count else {
                result.append(character)
                index += 1
                continue
            }

            let escaped = characters[index + 1]
            switch escaped {
            case "n":
                result.append("\n")
                index += 2
            case "r":
                result.append("\r")
                index += 2
            case "t":
                result.append("\t")
                index += 2
            case "0":
                result.append("\0")
                index += 2
            case "\\":
                result.append("\\")
                index += 2
            case "x":
                // \xHH — exactly two hex digits. A short or malformed escape
                // stays verbatim, matching the "unknown escape" rule above.
                if index + 3 < characters.count,
                   let high = hexValue(characters[index + 2]),
                   let low = hexValue(characters[index + 3]),
                   let scalar = UnicodeScalar(high * 16 + low) {
                    result.unicodeScalars.append(scalar)
                    index += 4
                } else {
                    result.append(character)
                    result.append(escaped)
                    index += 2
                }
            default:
                result.append(character)
                result.append(escaped)
                index += 2
            }
        }

        return result
    }

    private static func hexValue(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 48...57: return Int(ascii - 48)       // 0-9
        case 65...70: return Int(ascii - 55)       // A-F
        case 97...102: return Int(ascii - 87)      // a-f
        default: return nil
        }
    }
}
