import Foundation

extension LexerDefinition {

    /// The Kotlin grammar (Kotlin 2.x).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let kotlinSource = #"""
    {
      "language": "Kotlin",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(abstract|actual|annotation|as|break|by|catch|class|companion|const|constructor|continue|crossinline|data|delegate|do|dynamic|else|enum|expect|external|false|field|final|finally|for|fun|get|if|import|in|infix|init|inline|inner|interface|internal|is|lateinit|noinline|null|object|open|operator|out|override|package|param|private|property|protected|public|reified|return|sealed|set|super|suspend|tailrec|this|throw|true|try|typealias|typeof|val|var|vararg|when|where|while)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\\\"\\\"\\\"[\\s\\S]*?\\\"\\\"\\\"|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*')"
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
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[fFlLuU]*\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(Any|Boolean|Byte|Char|Double|Float|Int|Long|Short|String|Unit|Nothing|Array|List|MutableList|Set|MutableSet|Map|MutableMap|Pair|Triple|Sequence|Collection|Iterable|IntArray|LongArray|DoubleArray|BooleanArray|Result|Lazy|Regex|Exception|Throwable)\\b"
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

    /// The decoded Kotlin definition. Decoding happens once, lazily.
    public static let kotlin: LexerDefinition = {
        do {
            return try LexerDefinition(json: kotlinSource)
        } catch {
            preconditionFailure("Embedded Kotlin lexer definition is invalid: \(error)")
        }
    }()
}
