import Foundation

extension LexerDefinition {

    /// The Groovy grammar (Groovy 4).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Groovy uses `//` line comments and `/* ... */` block comments, plus the
    /// usual single/double/triple-quoted strings and the slashy `/.../` form.
    /// The slashy rule never crosses a newline, so a `*/` or a `//` sequence
    /// still tokenizes as comment text.
    public static let groovySource = #"""
    {
      "language": "Groovy",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:def|if|else|for|while|switch|case|break|continue|return|try|catch|finally|throw|throws|new|class|interface|trait|enum|package|import|extends|implements|static|final|void|public|private|protected|abstract|synchronized|volatile|transient|this|super|null|true|false|as|in|with|assert|instanceof|native|strictfp|default|goto|var)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "'''[\\s\\S]*?'''",
            "\"\"\"[\\s\\S]*?\"\"\"",
            "\"(?:[^\"\\\\]|\\\\.)*\"",
            "'(?:[^'\\\\]|\\\\.)*'",
            "/(?:[^/\\\\\\n]|\\\\.)*/"
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
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)[lLfFdDgGiI]?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:byte|short|int|long|float|double|boolean|char|String|Object|BigInteger|BigDecimal|List|Map|Set|Closure|Range|Number|Character|Boolean|Integer|Long|Float|Double|Class|File|Date|GString)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_$]\\w*(?=\\s*\\()"
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

    /// The decoded Groovy definition. Decoding happens once, lazily.
    public static let groovy: LexerDefinition = {
        do {
            return try LexerDefinition(json: groovySource)
        } catch {
            preconditionFailure("Embedded Groovy lexer definition is invalid: \(error)")
        }
    }()
}
