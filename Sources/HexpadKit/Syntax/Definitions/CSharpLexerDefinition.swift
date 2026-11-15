import Foundation

extension LexerDefinition {

    /// The C# grammar (C# 12).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let csharpSource = #"""
    {
      "language": "C#",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(abstract|as|base|bool|break|byte|case|catch|char|checked|class|const|continue|decimal|default|delegate|do|double|else|enum|event|explicit|extern|false|finally|fixed|float|for|foreach|goto|if|implicit|in|int|interface|internal|is|lock|long|namespace|new|null|object|operator|out|override|params|private|protected|public|readonly|record|ref|return|sbyte|sealed|short|sizeof|stackalloc|static|string|struct|switch|this|throw|true|try|typeof|uint|ulong|unchecked|unsafe|ushort|using|var|virtual|void|volatile|while|async|await|dynamic|get|init|nameof|partial|set|value|when|where|with|yield)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:@\"(?:[^\"]|\"\")*\"|\\$?\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'(?:[^'\\\\]|\\\\.)*')"
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
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[uUlLfFdDmM]*\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(Object|String|Boolean|Byte|SByte|Int16|UInt16|Int32|UInt32|Int64|UInt64|Single|Double|Decimal|Char|DateTime|TimeSpan|Guid|Array|List|Dictionary|HashSet|Queue|Stack|IEnumerable|IList|IDictionary|Task|ValueTask|Nullable|Exception|Console|Math|Convert|Span|Memory)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_]\\w*(?=\\s*\\()"
          ]
        }
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

    /// The decoded C# definition. Decoding happens once, lazily.
    public static let csharp: LexerDefinition = {
        do {
            return try LexerDefinition(json: csharpSource)
        } catch {
            preconditionFailure("Embedded C# lexer definition is invalid: \(error)")
        }
    }()
}
