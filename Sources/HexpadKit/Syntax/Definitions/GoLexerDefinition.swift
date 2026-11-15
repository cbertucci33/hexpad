import Foundation

extension LexerDefinition {

    /// The Go grammar (Go 1.22).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let goSource = #"""
    {
      "language": "Go",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var|true|false|nil|iota)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:`[^`]*`|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'(?:[^'\\\\]|\\\\.)*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)//[^\\n]*|(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?i?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr|any|comparable)\\b"
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

    /// The decoded Go definition. Decoding happens once, lazily.
    public static let go: LexerDefinition = {
        do {
            return try LexerDefinition(json: goSource)
        } catch {
            preconditionFailure("Embedded Go lexer definition is invalid: \(error)")
        }
    }()
}
