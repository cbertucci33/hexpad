import Foundation

extension LexerDefinition {

    /// The LaTeX grammar (LaTeX2e).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// LaTeX has commands (`\section`, `\begin`, `\textbf*`) rather than
    /// keywords, `%` line comments (an escaped `\%` is literal text), and `{}`
    /// grouping braces. Braces are the only bracket pair worth declaring;
    /// ordinary text between them is prose, so no string rule is invented.
    public static let latexSource = #"""
    {
      "language": "LaTeX",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\\\[a-zA-Z@]+\\*?"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?<!\\\\)%[^\\n]*"
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
        "linePrefix": "%"
      },
      "brackets": [
        { "open": "{", "close": "}" }
      ]
    }
    """#

    /// The decoded LaTeX definition. Decoding happens once, lazily.
    public static let latex: LexerDefinition = {
        do {
            return try LexerDefinition(json: latexSource)
        } catch {
            preconditionFailure("Embedded LaTeX lexer definition is invalid: \(error)")
        }
    }()
}
