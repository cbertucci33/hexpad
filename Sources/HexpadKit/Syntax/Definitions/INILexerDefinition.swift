import Foundation

extension LexerDefinition {

    /// The INI grammar (Windows INI / `.conf` style files).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// INI files accept both `;` and `#` comments. `CommentSyntax` only carries
    /// one line prefix, so `;` is the metadata default (the form Windows uses)
    /// while the highlighting rule still covers both. INI has no function
    /// construct; section headers are declared as `type`.
    public static let iniSource = #"""
    {
      "language": "INI",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(true|false|yes|no|on|off)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^']*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)[;#][^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b-?\\d+(?:\\.\\d+)?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "(?m)^\\s*\\[[^\\]\\n]+\\]"
          ]
        }
      ],
      "comments": {
        "linePrefix": ";"
      },
      "brackets": [
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded INI definition. Decoding happens once, lazily.
    public static let ini: LexerDefinition = {
        do {
            return try LexerDefinition(json: iniSource)
        } catch {
            preconditionFailure("Embedded INI lexer definition is invalid: \(error)")
        }
    }()
}
