import Foundation

extension LexerDefinition {

    /// The Pascal / Object Pascal grammar (`.pas`, `.dpr`, `.lpr`).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Pascal comments come in three spellings: `(* *)`, `{ }`, and `//`.
    /// Only the first is representable as the definition's single block-comment
    /// metadata pair, but the highlighter recognizes all three. Strings double
    /// an embedded quote rather than using a backslash escape. Keywords are
    /// case-insensitive. Parentheses and square brackets are the only bracket
    /// pairs worth declaring; `begin`/`end` are keywords, not bracket tokens.
    public static let pascalSource = #"""
    {
      "language": "Pascal",
      "rules": [
        {
          "name": "comment",
          "patterns": [
            "\\(\\*[\\s\\S]*?\\*\\)",
            "\\{[\\s\\S]*?\\}",
            "//[^\\n]*"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "'[^'\\n]*(?:''[^'\\n]*)*'"
          ]
        },
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(?:program|unit|uses|interface|implementation|begin|end|procedure|function|var|const|type|if|then|else|while|do|for|to|downto|repeat|until|case|of|record|with|goto|label|array|set|file|packed|div|mod|and|or|not|in|nil|true|false|try|except|finally|raise|constructor|destructor|inherited|property|class|operator|exit|break|continue)\\b"
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
        "linePrefix": "//",
        "blockStart": "(*",
        "blockEnd": "*)"
      },
      "brackets": [
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Pascal definition. Decoding happens once, lazily.
    public static let pascal: LexerDefinition = {
        do {
            return try LexerDefinition(json: pascalSource)
        } catch {
            preconditionFailure("Embedded Pascal lexer definition is invalid: \(error)")
        }
    }()
}
