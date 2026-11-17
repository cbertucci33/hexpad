import Foundation

extension LexerDefinition {

    /// The Racket grammar (Racket 8).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Racket has both `;` line comments and `#| ... |#` block comments. Block
    /// comments nest, but as with OCaml the regex is the non-greedy flat form,
    /// so a nested comment closes at the first `|#`.
    ///
    /// Racket symbols may contain `?`, `!`, `*`, `+`, `-`, `<`, `>`, and `/`,
    /// so word boundaries are replaced by explicit symbol-character guards.
    public static let racketSource = #"""
    {
      "language": "Racket",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?<![\\w!?*+\\-=<>/])(?:define-syntax-rule|define-syntax|define-values|define-struct|define/contract|define|lambda|letrec\\*|let-values|let\\*|letrec|let-syntax|letrec-syntax|let|cond|case|if|when|unless|do|require|provide|module\\*|module\\+|module|struct|syntax-rules|set!|begin|and|or|not|eq\\?|eqv\\?|equal\\?|car|cdr|cons|list|map|foldl|foldr|filter|apply|else|match-lambda|match\\*|match|quasiquote|unquote-splicing|unquote|quote|for/list|for/fold|for|values|void|call/cc|raise|error|displayln|printf|assert)(?![\\w!?*+\\-=<>/])"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "#?\"(?:[^\"\\\\]|\\\\.)*\"",
            "#\\\\(?:[a-zA-Z0-9]+|.)"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m);[^\\n]*|(?ms)#\\|[\\s\\S]*?\\|#"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:#x[0-9a-fA-F]+|#b[01]+|#o[0-7]+|\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:integer|exact-integer|number|real|rational|complex|boolean|string|symbol|keyword|char|bytes|vector|list|pair|procedure|hash|struct|port|void|any)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "(?<=\\(define )[\\w!?*+\\-=<>/]+",
            "(?<=\\(define \\()[\\w!?*+\\-=<>/]+",
            "(?<=\\(define-syntax )[\\w!?*+\\-=<>/]+",
            "(?<=\\(struct )[\\w!?*+\\-=<>/]+"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": ";",
        "blockStart": "#|",
        "blockEnd": "|#"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Racket definition. Decoding happens once, lazily.
    public static let racket: LexerDefinition = {
        do {
            return try LexerDefinition(json: racketSource)
        } catch {
            preconditionFailure("Embedded Racket lexer definition is invalid: \(error)")
        }
    }()
}
