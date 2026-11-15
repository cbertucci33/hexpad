import Foundation

extension LexerDefinition {

    /// The Swift grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.swift]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let swiftSource = #"""
    {
      "language": "Swift",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(func|let|var|if|else|guard|for|while|switch|case|return|class|struct|enum|protocol|extension|import|public|private|internal|static|final|override|init|deinit|self|nil|try|catch|throw|throws|async|await|defer|where|in|is|as|some|any)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"\"\"[\\s\\S]*?\"\"\"|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\")"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)(?:^|[^\\\\])\\/\\/[^\\n]*|(?ms)\\/\\*[\\s\\S]*?\\*\\/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(Int|String|Double|Bool|Array|Dictionary|Optional)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_]\\w*(?=\\s*\\()"
          ]
        }
      ]
    }
    """#

    /// The decoded Swift definition. Decoding happens once, lazily.
    public static let swift: LexerDefinition = {
        do {
            return try LexerDefinition(json: swiftSource)
        } catch {
            preconditionFailure("Embedded Swift lexer definition is invalid: \(error)")
        }
    }()
}
