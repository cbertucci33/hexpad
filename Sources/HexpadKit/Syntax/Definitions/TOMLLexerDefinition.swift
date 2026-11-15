import Foundation

extension LexerDefinition {

    /// The TOML grammar (TOML 1.0).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// TOML has no function construct. Table headers (`[table]`,
    /// `[[array]]`) are declared as `type` because they are the file's only
    /// structural declaration.
    public static let tomlSource = #"""
    {
      "language": "TOML",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(true|false)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\\\"\\\"\\\"[\\s\\S]*?\\\"\\\"\\\"|'''[\\s\\S]*?'''|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^']*')"
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
            "\\b\\d{4}-\\d{2}-\\d{2}(?:[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})?)?\\b",
            "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "(?m)^\\s*\\[\\[?[^\\]\\n]+\\]\\]?"
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

    /// The decoded TOML definition. Decoding happens once, lazily.
    public static let toml: LexerDefinition = {
        do {
            return try LexerDefinition(json: tomlSource)
        } catch {
            preconditionFailure("Embedded TOML lexer definition is invalid: \(error)")
        }
    }()
}
