import Foundation

extension LexerDefinition {

    /// The PHP grammar (PHP 8.x).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let phpSource = #"""
    {
      "language": "PHP",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(abstract|and|array|as|break|callable|case|catch|class|clone|const|continue|declare|default|do|echo|else|elseif|empty|enum|extends|final|finally|fn|for|foreach|function|global|goto|if|implements|include|include_once|instanceof|insteadof|interface|isset|list|match|namespace|new|or|print|private|protected|public|readonly|require|require_once|return|static|switch|throw|trait|try|unset|use|var|while|xor|yield|true|false|null)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)//[^\\n]*|(?m)#(?!\\[)[^\\n]*|(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(int|float|string|bool|array|object|callable|iterable|mixed|void|never|self|parent|static|false|true|null)\\b"
          ]
        },
        {
          "name": "variable",
          "patterns": [
            "\\$[a-zA-Z_]\\w*"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_]\\w*(?=\\s*\\()"
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

    /// The decoded PHP definition. Decoding happens once, lazily.
    public static let php: LexerDefinition = {
        do {
            return try LexerDefinition(json: phpSource)
        } catch {
            preconditionFailure("Embedded PHP lexer definition is invalid: \(error)")
        }
    }()
}
