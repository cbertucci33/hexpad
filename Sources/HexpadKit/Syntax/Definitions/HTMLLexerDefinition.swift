import Foundation

extension LexerDefinition {

    /// The HTML grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.html]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    ///
    /// Comments are `<!-- ... -->`; HTML has no line-comment form. Tag pairs
    /// are the natural fold construct, but `LexerDefinition.BracketPair` only
    /// matches literal delimiters, and a tag pair's delimiter includes the tag
    /// name (`<div>` ... `</div>`). The definition therefore leaves `brackets`
    /// empty instead of declaring `<`/`>`, which would fold text and
    /// comparison-like runs that are not elements.
    public static let htmlSource = #"""
    {
      "language": "HTML",
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
      ],
      "comments": {
        "blockStart": "<!--",
        "blockEnd": "-->"
      }
    }
    """#

    /// The decoded HTML definition. Decoding happens once, lazily.
    public static let html: LexerDefinition = {
        do {
            return try LexerDefinition(json: htmlSource)
        } catch {
            preconditionFailure("Embedded HTML lexer definition is invalid: \(error)")
        }
    }()
}
