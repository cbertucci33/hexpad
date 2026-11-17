import Foundation

extension LexerDefinition {

    /// The Perl grammar (Perl 5.38).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Perl has no true block comment; POD (`=pod` ... `=cut`, and the
    /// `=begin`/`=end` form) is the closest construct and is declared as the
    /// block comment so folding can treat it as one region.
    public static let perlSource = #"""
    {
      "language": "Perl",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:my|our|local|state|sub|if|elsif|else|unless|while|until|for|foreach|do|last|next|redo|return|package|use|no|require|BEGIN|END|CHECK|INIT|UNITCHECK|and|or|not|xor|eq|ne|lt|gt|le|ge|cmp|isa|undef|defined|exists|delete|die|warn|eval|print|printf|say|chomp|chop|split|join|map|grep|sort|keys|values|each|push|pop|shift|unshift|splice|ref|bless|wantarray|scalar|caller|goto|given|when|default|continue|format)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`|\\bq[qwx]?\\s*(?:\\([^)]*\\)|\\{[^}]*\\}|\\[[^\\]]*\\]|<[^>]*>|/[^/]*/))"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)^=(?:pod|head[1-4]|over|item|back|begin|for|encoding)\\b[\\s\\S]*?^=(?:cut|end)\\b[^\\n]*|(?m)#[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:SCALAR|ARRAY|HASH|CODE|GLOB|REF|LVALUE|FORMAT|IO)\\b"
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
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "#",
        "blockStart": "=pod",
        "blockEnd": "=cut"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Perl definition. Decoding happens once, lazily.
    public static let perl: LexerDefinition = {
        do {
            return try LexerDefinition(json: perlSource)
        } catch {
            preconditionFailure("Embedded Perl lexer definition is invalid: \(error)")
        }
    }()
}
