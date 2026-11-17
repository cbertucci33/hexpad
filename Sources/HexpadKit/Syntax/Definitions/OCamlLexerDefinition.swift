import Foundation

extension LexerDefinition {

    /// The OCaml grammar (OCaml 5).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// OCaml has no line-comment form; `(* ... *)` is the only comment. Block
    /// comments nest, but as with Haskell the regex is the non-greedy flat form,
    /// so a nested comment closes at the first `*)`.
    ///
    /// The function rule uses fixed-width lookbehind for the `let`/`let rec`/
    /// `and` binding forms rather than matching every identifier before a space.
    public static let ocamlSource = #"""
    {
      "language": "OCaml",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:and|as|assert|asr|begin|class|constraint|do|done|downto|else|end|exception|external|false|for|fun|function|functor|if|in|include|inherit|initializer|land|lazy|let|lor|lsl|lsr|lxor|match|method|mod|module|mutable|new|nonrec|object|of|open|or|private|rec|sig|struct|then|to|true|try|type|val|virtual|when|while|with)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"(?:[^\"\\\\]|\\\\.)*\"",
            "'(?:[^'\\\\]|\\\\.)'",
            "\\{[a-z_]*\\|[\\s\\S]*?\\|[a-z_]*\\}"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?ms)\\(\\*[\\s\\S]*?\\*\\)"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d[\\d_]*)?)[lLn]?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:int|float|string|bool|char|unit|list|array|option|bytes|int32|int64|nativeint|ref|exn|format|format4|format6|in_channel|out_channel|Result|Some|None|Ok|Error)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "(?<=let )[a-z_][\\w']*",
            "(?<=let rec )[a-z_][\\w']*",
            "(?<=and )[a-z_][\\w']*"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
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

    /// The decoded OCaml definition. Decoding happens once, lazily.
    public static let ocaml: LexerDefinition = {
        do {
            return try LexerDefinition(json: ocamlSource)
        } catch {
            preconditionFailure("Embedded OCaml lexer definition is invalid: \(error)")
        }
    }()
}
