import Foundation

extension LexerDefinition {

    /// The Java grammar (Java 21).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let javaSource = #"""
    {
      "language": "Java",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|var|void|volatile|while|record|sealed|permits|non-sealed|yield|true|false|null)\\b"
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
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)[lLfFdD]?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(String|Object|Integer|Long|Short|Byte|Double|Float|Boolean|Character|Number|BigInteger|BigDecimal|List|ArrayList|LinkedList|Map|HashMap|TreeMap|Set|HashSet|TreeSet|Collection|Collections|Arrays|Optional|Stream|Function|Consumer|Supplier|Predicate|Thread|Runnable|Exception|RuntimeException|Error|System|Math)\\b"
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

    /// The decoded Java definition. Decoding happens once, lazily.
    public static let java: LexerDefinition = {
        do {
            return try LexerDefinition(json: javaSource)
        } catch {
            preconditionFailure("Embedded Java lexer definition is invalid: \(error)")
        }
    }()
}
