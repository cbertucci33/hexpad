import Foundation

extension LexerDefinition {

    /// The JSON grammar, migrated from `SyntaxTokenizer.languageRules[.json]`.
    ///
    /// The source of truth is the JSON text below rather than a `.json`
    /// resource file. `Package.swift` declares no `resources:` for the
    /// `HexpadKit` target, so a loose `.json` file would be reported as an
    /// unhandled resource and would not be present in the built module unless
    /// the manifest were changed. Keeping the JSON as an embedded string
    /// preserves the data-driven format while staying inside the Syntax scope.
    public static let jsonSource = #"""
    {
      "language": "JSON",
      "rules": [
        {
          "name": "keyword",
          "patterns": ["true", "false", "null"]
        },
        {
          "name": "number",
          "patterns": ["-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?"]
        },
        {
          "name": "punctuation",
          "patterns": ["[{}\\[\\],:]"]
        },
        {
          "name": "string",
          "patterns": ["\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\""]
        }
      ],
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded JSON definition. Decoding happens once, lazily.
    public static let json: LexerDefinition = {
        do {
            return try LexerDefinition(json: jsonSource)
        } catch {
            preconditionFailure("Embedded JSON lexer definition is invalid: \(error)")
        }
    }()
}
