import Foundation

extension LexerDefinition {

    /// The YAML grammar (YAML 1.2).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// YAML has no function construct. Tags (`!!str`, `!Ref`) are declared as
    /// `type`, and anchors/aliases (`&name`, `*name`) as `variable`, which is
    /// how the rest of the definitions name non-keyword identifiers.
    public static let yamlSource = #"""
    {
      "language": "YAML",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(true|false|null|yes|no|on|off)\\b",
            "~"
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
            "(?m)#[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "!!?[a-zA-Z][\\w!-]*"
          ]
        },
        {
          "name": "variable",
          "patterns": [
            "[&*][a-zA-Z_][\\w-]*"
          ]
        }
      ],
      "comments": {
        "linePrefix": "#"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded YAML definition. Decoding happens once, lazily.
    public static let yaml: LexerDefinition = {
        do {
            return try LexerDefinition(json: yamlSource)
        } catch {
            preconditionFailure("Embedded YAML lexer definition is invalid: \(error)")
        }
    }()
}
