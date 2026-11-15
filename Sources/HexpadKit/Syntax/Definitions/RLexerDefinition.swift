import Foundation

extension LexerDefinition {

    /// The R grammar (R 4.x).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// R has no block comments, so only the `#` line form is declared.
    public static let rSource = #"""
    {
      "language": "R",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(if|else|repeat|while|function|for|in|next|break|TRUE|FALSE|NULL|Inf|NaN|NA|NA_integer_|NA_real_|NA_character_|NA_complex_|library|require|return)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)#[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[Li]?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(character|numeric|double|integer|logical|complex|list|vector|matrix|array|data\\.frame|factor|environment|function)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_.][\\w.]*(?=\\s*\\()"
          ]
        }
      ],
      "comments": {
        "linePrefix": "#"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded R definition. Decoding happens once, lazily.
    public static let r: LexerDefinition = {
        do {
            return try LexerDefinition(json: rSource)
        } catch {
            preconditionFailure("Embedded R lexer definition is invalid: \(error)")
        }
    }()
}
