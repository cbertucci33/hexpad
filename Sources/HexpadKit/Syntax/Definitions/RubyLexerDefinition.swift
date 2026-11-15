import Foundation

extension LexerDefinition {

    /// The Ruby grammar (Ruby 3.x).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let rubySource = #"""
    {
      "language": "Ruby",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(alias|and|begin|break|case|class|def|defined\\?|do|else|elsif|end|ensure|false|for|if|in|module|next|nil|not|or|redo|rescue|retry|return|self|super|then|true|undef|unless|until|when|while|yield|require|require_relative|include|extend|prepend|attr_accessor|attr_reader|attr_writer|private|protected|public|module_function|lambda|proc|raise|rescue|ensure)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)#[^\\n]*|(?ms)^=begin\\b.*?^=end\\b.*$"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(Integer|Float|Numeric|String|Symbol|Array|Hash|Range|Regexp|Proc|Lambda|NilClass|TrueClass|FalseClass|Object|Class|Module|Complex|Rational|Exception|StandardError)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\bdef\\s+[a-zA-Z_]\\w*[?!]?",
            "\\b[a-zA-Z_]\\w*[?!]?(?=\\s*\\()"
          ]
        }
      ],
      "comments": {
        "linePrefix": "#",
        "blockStart": "=begin",
        "blockEnd": "=end"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Ruby definition. Decoding happens once, lazily.
    public static let ruby: LexerDefinition = {
        do {
            return try LexerDefinition(json: rubySource)
        } catch {
            preconditionFailure("Embedded Ruby lexer definition is invalid: \(error)")
        }
    }()
}
