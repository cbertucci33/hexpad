import Foundation

extension LexerDefinition {

    /// The F# grammar (F# 8).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// F# uses `//` line comments and `(* ... *)` block comments. Block comments
    /// nest, but as with OCaml the regex is the non-greedy flat form, so a
    /// nested comment closes at the first `*)`.
    ///
    /// Strings cover triple-quoted (`"""..."""`) and verbatim (`@"..."`) forms;
    /// the triple-quoted rule is listed first so it wins the longest-match tie
    /// against the plain string rule.
    public static let fsharpSource = #"""
    {
      "language": "F#",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?<![\\w!'])(?:abstract|and|as|assert|base|begin|class|default|delegate|do|done|downcast|downto|elif|else|end|exception|extern|false|finally|fixed|for|fun|function|global|if|in|inherit|inline|interface|internal|lazy|match!|match|member|module|mutable|namespace|new|not|null|of|open|or|override|private|public|rec|return!|return|select|static|struct|then|to|true|try|type|upcast|use!|use|val|void|when|while|with|yield!|yield|let!|let)(?![\\w!'])"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"\"\"[\\s\\S]*?\"\"\"",
            "@\"(?:[^\"]|\"\")*\"",
            "\"(?:[^\"\\\\]|\\\\.)*\"",
            "'(?:[^'\\\\]|\\\\.)'"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)//[^\\n]*|(?ms)\\(\\*[\\s\\S]*?\\*\\)"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)[uUlLfFmM]?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:bool|byte|sbyte|char|decimal|double|float|int|int16|int32|int64|uint16|uint32|uint64|nativeint|unativeint|string|obj|unit|list|array|seq|option|voption|map|set|ResizeArray|Result|Async|Task|exn|bigint|Guid|DateTime|TimeSpan)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "(?<=let )[\\w']+",
            "(?<=let rec )[\\w']+",
            "(?<=let mutable )[\\w']+",
            "(?<=member )[\\w'.]+",
            "(?<=and )[\\w']+",
            "(?<=use )[\\w']+"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "//",
        "blockStart": "(*",
        "blockEnd": "*)"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded F# definition. Decoding happens once, lazily.
    public static let fsharp: LexerDefinition = {
        do {
            return try LexerDefinition(json: fsharpSource)
        } catch {
            preconditionFailure("Embedded F# lexer definition is invalid: \(error)")
        }
    }()
}
