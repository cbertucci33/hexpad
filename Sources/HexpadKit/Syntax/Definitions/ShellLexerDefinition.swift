import Foundation

extension LexerDefinition {

    /// The Shell grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.shell]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let shellSource = #"""
    {
      "language": "Shell",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|select|until|in|time|coproc)\\b"
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
            "(?m)#[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+\\b"
          ]
        },
        {
          "name": "variable",
          "patterns": [
            "\\$\\{?[\\w@#*?!$]+\\}?"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_][\\w]*\\s*\\(\\)"
          ]
        },
        {
          "name": "operator",
          "patterns": [
            "[|&;<>`=\\]"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
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

    /// The decoded Shell definition. Decoding happens once, lazily.
    public static let shell: LexerDefinition = {
        do {
            return try LexerDefinition(json: shellSource)
        } catch {
            preconditionFailure("Embedded Shell lexer definition is invalid: \(error)")
        }
    }()
}
