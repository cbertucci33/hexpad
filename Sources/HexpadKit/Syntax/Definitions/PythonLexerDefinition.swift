import Foundation

extension LexerDefinition {

    /// The Python grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.python]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let pythonSource = #"""
    {
      "language": "Python",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(def|class|if|elif|else|while|for|in|return|import|from|as|with|try|except|finally|raise|pass|break|continue|and|or|not|is|None|True|False|lambda|yield|global|nonlocal|assert|del)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:'''[\\s\\S]*?'''|\\\"\\\"\\\"[\\s\\S]*?\\\"\\\"\\\"|'[^']*'|\\\"[^\\\"]*\\\")"
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
            "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?j?\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_]\\w*(?=\\s*\\()"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(bool|int|float|str|list|dict|tuple|set|None|object|Any|Optional|Union|Type)\\b"
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

    /// The decoded Python definition. Decoding happens once, lazily.
    public static let python: LexerDefinition = {
        do {
            return try LexerDefinition(json: pythonSource)
        } catch {
            preconditionFailure("Embedded Python lexer definition is invalid: \(error)")
        }
    }()
}
