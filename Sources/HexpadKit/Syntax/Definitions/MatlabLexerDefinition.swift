import Foundation

extension LexerDefinition {

    /// The MATLAB grammar (MATLAB R2024a).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// `%{` ... `%}` is the block comment form; `%` alone starts a line
    /// comment. String and char-array literals share the single-quote token:
    /// MATLAB distinguishes them by context, which a regex lexer cannot, so
    /// both `'text'` (char array) and `"text"` (string) are declared.
    public static let matlabSource = #"""
    {
      "language": "MATLAB",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:break|case|catch|classdef|continue|else|elseif|end|for|function|global|if|otherwise|parfor|persistent|return|spmd|switch|try|while|arguments|properties|methods|events|enumeration|import)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:'(?:[^'\\n]|'')*'|\"(?:[^\"\\n]|\"\")*\")"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)^[ \\t]*%\\{[\\s\\S]*?^[ \\t]*%\\}|(?m)%.*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|\\d+(?:\\.\\d*)?(?:[eE][+-]?\\d+)?[ij]?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:double|single|int8|int16|int32|int64|uint8|uint16|uint32|uint64|logical|char|string|cell|struct|table|timetable|function_handle|datetime|duration|calendarDuration|categorical)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[A-Za-z]\\w*(?=\\s*\\()"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "%",
        "blockStart": "%{",
        "blockEnd": "%}"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded MATLAB definition. Decoding happens once, lazily.
    public static let matlab: LexerDefinition = {
        do {
            return try LexerDefinition(json: matlabSource)
        } catch {
            preconditionFailure("Embedded MATLAB lexer definition is invalid: \(error)")
        }
    }()
}
