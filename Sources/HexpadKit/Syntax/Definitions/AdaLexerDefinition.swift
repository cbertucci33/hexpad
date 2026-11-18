import Foundation

extension LexerDefinition {

    /// The Ada grammar (Ada 2012; `.adb` bodies and `.ads` specs).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Ada has `--` line comments, strings that double an embedded quote, and
    /// case-insensitive keywords including `elsif`. Parentheses are the only
    /// structural bracket pair; `begin`/`end` delimit blocks with words, not
    /// with bracket characters, so they stay keywords.
    public static let adaSource = #"""
    {
      "language": "Ada",
      "rules": [
        {
          "name": "comment",
          "patterns": [
            "--[^\\n]*"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"(?:[^\"]|\"\")*\""
          ]
        },
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(?:with|use|procedure|function|package|body|is|begin|end|if|then|elsif|else|while|loop|for|in|reverse|declare|record|type|subtype|constant|variable|out|return|raise|exception|when|new|private|generic|pragma|null|abs|mod|rem|and|or|not|xor|true|false|entry|accept|select|task|protected|separate|abort|delay|goto|case|others|range|access|aliased|tagged|limited|interface|synchronized)\\b"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?\\b"
          ]
        }
      ],
      "comments": {
        "linePrefix": "--"
      },
      "brackets": [
        { "open": "(", "close": ")" }
      ]
    }
    """#

    /// The decoded Ada definition. Decoding happens once, lazily.
    public static let ada: LexerDefinition = {
        do {
            return try LexerDefinition(json: adaSource)
        } catch {
            preconditionFailure("Embedded Ada lexer definition is invalid: \(error)")
        }
    }()
}
