import Foundation

extension LexerDefinition {

    /// The XML grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.xml]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let xmlSource = #"""
    {
      "language": "XML",
      "rules": [
        {
          "name": "tag",
          "patterns": [
            "<[a-zA-Z][a-zA-Z0-9]*"
          ]
        },
        {
          "name": "closing_tag",
          "patterns": [
            "</[a-zA-Z][a-zA-Z0-9]*>"
          ]
        },
        {
          "name": "attribute",
          "patterns": [
            "[a-zA-Z:-][a-zA-Z0-9:-]*(?=\\s*=)"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\""
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?ms)<!--[\\s\\S]*?-->"
          ]
        },
        {
          "name": "entity",
          "patterns": [
            "&[a-zA-Z0-9#];"
          ]
        }
      ]
    }
    """#

    /// The decoded XML definition. Decoding happens once, lazily.
    public static let xml: LexerDefinition = {
        do {
            return try LexerDefinition(json: xmlSource)
        } catch {
            preconditionFailure("Embedded XML lexer definition is invalid: \(error)")
        }
    }()
}
