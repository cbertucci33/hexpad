import Foundation

extension LexerDefinition {

    /// The Dart grammar (Dart 3).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Raw strings (`r'...'`, `r"..."`, and their triple-quoted forms) are
    /// matched by the string rule so `\` inside them stays inert. Block comments
    /// nest in Dart; as with Haskell and Rust the regex is the non-greedy flat
    /// form, so a nested `/* */` closes at the first `*/`.
    public static let dartSource = #"""
    {
      "language": "Dart",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:abstract|as|assert|async|await|base|break|case|catch|class|const|continue|covariant|default|deferred|do|dynamic|else|enum|export|extends|extension|external|factory|false|final|finally|for|Function|get|hide|if|implements|import|in|interface|is|late|library|mixin|new|null|on|operator|part|required|rethrow|return|sealed|set|show|static|super|switch|sync|this|throw|true|try|typedef|var|void|when|while|with|yield)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "[rR]?'''(?:[^'\\\\]|\\\\.)*'''|[rR]?\"\"\"(?:[^\"\\\\]|\\\\.)*\"\"\"|[rR]?'(?:[^'\\\\]|\\\\.)*'|[rR]?\"(?:[^\"\\\\]|\\\\.)*\""
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
            "\\b(?:0[xX][0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:bool|int|double|num|String|List|Map|Set|Object|Null|Never|Future|Stream|Iterable|Iterator|Duration|DateTime|RegExp|Symbol|Type|Record|Comparable|Enum|Error|Exception)\\b"
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

    /// The decoded Dart definition. Decoding happens once, lazily.
    public static let dart: LexerDefinition = {
        do {
            return try LexerDefinition(json: dartSource)
        } catch {
            preconditionFailure("Embedded Dart lexer definition is invalid: \(error)")
        }
    }()
}
