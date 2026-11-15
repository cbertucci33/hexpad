import Foundation

extension LexerDefinition {

    /// The CSS grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.css]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let cssSource = #"""
    {
      "language": "CSS",
      "rules": [
        {
          "name": "comment",
          "patterns": [
            "(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "selector",
          "patterns": [
            "[.#]?[a-zA-Z_-][a-zA-Z0-9_-]*(?=\\s*\\{)"
          ]
        },
        {
          "name": "property",
          "patterns": [
            "(?m)\\s([a-zA-Z-]+)\\s*:"
          ]
        },
        {
          "name": "value",
          "patterns": [
            "(?<=:)[^;{}]+(?=;)"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?(%|px|em|rem|pt|vh|vw|vmin|vmax|deg|rad|turn|s|ms)?\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\""
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z-]+(?=\\()"
          ]
        }
      ],
      "symbols": [
        { "rule": "selector", "kind": "selector" }
      ],
      "comments": {
        "blockStart": "/*",
        "blockEnd": "*/"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded CSS definition. Decoding happens once, lazily.
    public static let css: LexerDefinition = {
        do {
            return try LexerDefinition(json: cssSource)
        } catch {
            preconditionFailure("Embedded CSS lexer definition is invalid: \(error)")
        }
    }()
}
