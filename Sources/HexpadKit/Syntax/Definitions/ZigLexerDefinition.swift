import Foundation

extension LexerDefinition {

    /// The Zig grammar (Zig 0.13).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Zig has no block comment form; `//` is the only comment syntax, so
    /// `comments` declares no block delimiters.
    public static let zigSource = #"""
    {
      "language": "Zig",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:addrspace|align|allowzero|and|anyframe|anytype|asm|async|await|break|callconv|catch|comptime|const|continue|defer|else|enum|errdefer|error|export|extern|fn|for|if|inline|linksection|nakedcc|noalias|noinline|nosuspend|not|opaque|or|orelse|packed|pub|resume|return|struct|suspend|switch|test|threadlocal|try|type|union|unreachable|usingnamespace|var|volatile|while|unwrap|true|false|null|undefined)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"(?:[^\"\\\\]|\\\\.)*\"",
            "'(?:[^'\\\\]|\\\\.)'"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)//[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f16|f32|f64|f80|f128|c_int|c_uint|c_long|c_ulong|c_longlong|c_ulonglong|c_short|c_ushort|bool|void|noreturn|anyerror|anyframe|anytype|comptime_int|comptime_float)\\b"
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
        "linePrefix": "//"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Zig definition. Decoding happens once, lazily.
    public static let zig: LexerDefinition = {
        do {
            return try LexerDefinition(json: zigSource)
        } catch {
            preconditionFailure("Embedded Zig lexer definition is invalid: \(error)")
        }
    }()
}
