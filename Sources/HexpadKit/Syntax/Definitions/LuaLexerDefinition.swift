import Foundation

extension LexerDefinition {

    /// The Lua grammar (Lua 5.4).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Lua block comments and long strings both use long brackets (`--[[`
    /// through `]]`), so the block declaration uses the comment-specific form.
    public static let luaSource = #"""
    {
      "language": "Lua",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(and|break|do|else|elseif|end|false|for|function|goto|if|in|local|nil|not|or|repeat|return|then|true|until|while)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:\\[\\[[\\s\\S]*?\\]\\]|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)--[^\\n]*|(?ms)--\\[\\[[\\s\\S]*?\\]\\]"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(nil|boolean|number|string|table|function|userdata|thread)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b(?:function\\s+)?[a-zA-Z_]\\w*(?=\\s*\\()"
          ]
        }
      ],
      "comments": {
        "linePrefix": "--",
        "blockStart": "--[[",
        "blockEnd": "]]"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Lua definition. Decoding happens once, lazily.
    public static let lua: LexerDefinition = {
        do {
            return try LexerDefinition(json: luaSource)
        } catch {
            preconditionFailure("Embedded Lua lexer definition is invalid: \(error)")
        }
    }()
}
