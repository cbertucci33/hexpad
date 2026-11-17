import Foundation

extension LexerDefinition {

    /// The Nim grammar (Nim 2).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Nim uses `#` line comments and `#[ ... ]#` block comments. Block comments
    /// nest, but as with OCaml the regex is the non-greedy flat form, so a
    /// nested comment closes at the first `]#`.
    public static let nimSource = #"""
    {
      "language": "Nim",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:addr|and|as|asm|bind|block|break|case|cast|concept|const|continue|converter|defer|discard|distinct|div|do|elif|else|end|enum|except|export|finally|for|from|func|if|import|in|include|interface|is|isnot|iterator|let|macro|method|mixin|mod|nil|not|notin|object|of|or|out|proc|ptr|raise|ref|return|shl|shr|static|template|try|tuple|type|using|var|when|while|xor|yield|true|false)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"\"\"[\\s\\S]*?\"\"\"",
            "[rR]?\"(?:[^\"\\\\]|\\\\.)*\"",
            "'(?:[^'\\\\]|\\\\.)'"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)#[^\\n]*|(?ms)#\\[[\\s\\S]*?\\]#"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)(?:'[if]?\\d+)?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|float64|bool|char|string|cstring|byte|Natural|Positive|seq|array|set|range|openArray|Table|OrderedTable|HashSet|Option|Result|ref|ptr|void)\\b"
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
        "linePrefix": "#",
        "blockStart": "#[",
        "blockEnd": "]#"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Nim definition. Decoding happens once, lazily.
    public static let nim: LexerDefinition = {
        do {
            return try LexerDefinition(json: nimSource)
        } catch {
            preconditionFailure("Embedded Nim lexer definition is invalid: \(error)")
        }
    }()
}
