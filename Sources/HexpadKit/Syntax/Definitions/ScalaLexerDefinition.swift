import Foundation

extension LexerDefinition {

    /// The Scala grammar (Scala 3, with Scala 2 keywords retained).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Scala block comments nest; the regex is the non-greedy flat form.
    /// Triple-quoted strings are matched before ordinary strings, and a
    /// single-quoted literal is a char if it closes (`'a'`) and a Scala 2
    /// symbol otherwise (`'name`).
    public static let scalaSource = #"""
    {
      "language": "Scala",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:abstract|case|catch|class|def|do|else|enum|export|extends|extension|false|final|finally|for|forSome|given|if|implicit|import|inline|lazy|match|new|null|object|opaque|open|override|package|private|protected|return|sealed|super|then|this|throw|trait|transparent|true|try|type|using|val|var|while|with|yield|end)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"\"\"[\\s\\S]*?\"\"\"|\"(?:[^\"\\\\]|\\\\.)*\"|'(?:\\\\u[0-9a-fA-F]{4}|\\\\[^']+|[^'\\\\])'|'[A-Za-z_]\\w*"
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
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)[lLfFdD]?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:Int|Long|Short|Byte|Float|Double|Boolean|Char|String|Unit|Any|AnyRef|AnyVal|Nothing|Null|Array|Seq|IndexedSeq|List|Vector|Set|Map|Option|Some|None|Either|Left|Right|Future|Promise|Try|Success|Failure|BigInt|BigDecimal|Ordering|Numeric|ClassTag|Iterable|Iterator|Range|Tuple\\d*)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[A-Za-z_]\\w*(?=\\s*\\()"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "method" }
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

    /// The decoded Scala definition. Decoding happens once, lazily.
    public static let scala: LexerDefinition = {
        do {
            return try LexerDefinition(json: scalaSource)
        } catch {
            preconditionFailure("Embedded Scala lexer definition is invalid: \(error)")
        }
    }()
}
