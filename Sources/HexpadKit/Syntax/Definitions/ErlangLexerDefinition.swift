import Foundation

extension LexerDefinition {

    /// The Erlang grammar (OTP 26).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Erlang has no block comment; `%` is the only comment form, so `comments`
    /// declares no block delimiters. Quoted atoms (`'...'`) and `$c` character
    /// literals are matched as strings so keywords inside them stay inert.
    public static let erlangSource = #"""
    {
      "language": "Erlang",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:after|and|andalso|band|begin|bnot|bor|bsl|bsr|bxor|case|catch|cond|div|else|end|fun|if|let|maybe|not|of|or|orelse|receive|rem|try|when|xor)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"(?:[^\"\\\\]|\\\\.)*\"",
            "'(?:[^'\\\\]|\\\\.)*'",
            "\\$(?:\\\\.|.)"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)%[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:\\d+#[0-9a-zA-Z_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:integer|float|atom|list|map|tuple|binary|bitstring|pid|port|reference|boolean|string|number|term|any|none|arity|byte|char|iodata|iolist|non_neg_integer|pos_integer|neg_integer|mfa|module|node|timeout|no_return|record)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-z][\\w@]*(?=\\s*\\()"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "%"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Erlang definition. Decoding happens once, lazily.
    public static let erlang: LexerDefinition = {
        do {
            return try LexerDefinition(json: erlangSource)
        } catch {
            preconditionFailure("Embedded Erlang lexer definition is invalid: \(error)")
        }
    }()
}
