import Foundation

extension LexerDefinition {

    /// The C grammar (C11/C17).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let cSource = #"""
    {
      "language": "C",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|inline|int|long|register|restrict|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|_Alignas|_Alignof|_Atomic|_Bool|_Complex|_Generic|_Imaginary|_Noreturn|_Static_assert|_Thread_local|bool|true|false|NULL)\\b"
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
            "(?m)//[^\\n]*|(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|\\d+(?:\\.\\d*)?(?:[eE][+-]?\\d+)?)[uUlLfF]*\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(size_t|ssize_t|ptrdiff_t|intptr_t|uintptr_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|wchar_t|FILE|va_list)\\b"
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

    /// The decoded C definition. Decoding happens once, lazily.
    public static let c: LexerDefinition = {
        do {
            return try LexerDefinition(json: cSource)
        } catch {
            preconditionFailure("Embedded C lexer definition is invalid: \(error)")
        }
    }()
}
