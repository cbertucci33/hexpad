import Foundation

extension LexerDefinition {

    /// The Haskell grammar (Haskell 2010, plus common GHC extensions).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Haskell block comments nest; the regex is the non-greedy flat form, so a
    /// nested `{- -}` inside a comment closes at the first `-}`. Character
    /// literals are matched as one character or one escape, which keeps the
    /// prime in an identifier like `x'` from opening a string token.
    public static let haskellSource = #"""
    {
      "language": "Haskell",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:case|class|data|default|deriving|do|else|foreign|if|import|in|infix|infixl|infixr|instance|let|module|newtype|of|then|type|where|as|qualified|hiding|forall|mdo|rec|proc|family|role|pattern|static|via|stock|anyclass|signature)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"(?:[^\"\\\\]|\\\\.)*\"|'(?:\\\\[^']+|[^'\\\\])')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)--[^\\n]*|(?m)\\{-[\\s\\S]*?-\\}"
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
            "\\b(?:Int|Integer|Float|Double|Char|String|Bool|Maybe|Either|IO|Word|Word8|Word16|Word32|Word64|Int8|Int16|Int32|Int64|Ordering|Rational|Show|Eq|Ord|Read|Enum|Bounded|Functor|Applicative|Monad|Foldable|Traversable|Semigroup|Monoid|Text|ByteString|Map|Set|Seq|Vector|Array|Ratio|Complex)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-z_][\\w']*(?=\\s*\\()",
            "\\b[a-z_][\\w']*(?=\\s*::)"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "--",
        "blockStart": "{-",
        "blockEnd": "-}"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Haskell definition. Decoding happens once, lazily.
    public static let haskell: LexerDefinition = {
        do {
            return try LexerDefinition(json: haskellSource)
        } catch {
            preconditionFailure("Embedded Haskell lexer definition is invalid: \(error)")
        }
    }()
}
