import Foundation

extension LexerDefinition {

    /// The TypeScript grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.typescript]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let typescriptSource = #"""
    {
      "language": "TypeScript",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(const|let|var|function|if|else|while|for|switch|case|break|continue|return|new|this|class|extends|interface|type|enum|implements|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|declare|abstract|readonly|as|is|keyof|namespace|module|package)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:`[^`]*`|'[^']*'|\\\"[^\\\"]*\\\")"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)(?:^|[^\\\\])\\/\\/[^\\n]*|#\"(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?(?:n)?\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_$]\\w*(?=\\s*\\()"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(String|Number|Boolean|Object|Array|Function|Symbol|undefined|null|void|never|any|unknown|true|false|Promise|Map|Set|Partial|Required|Record|Pick|Omit|Exclude|Extract|NonNullable|ReturnType|Parameters|InstanceType)\\b"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "//",
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

    /// The decoded TypeScript definition. Decoding happens once, lazily.
    public static let typescript: LexerDefinition = {
        do {
            return try LexerDefinition(json: typescriptSource)
        } catch {
            preconditionFailure("Embedded TypeScript lexer definition is invalid: \(error)")
        }
    }()
}
