import Foundation

extension LexerDefinition {

    /// The JavaScript grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.javascript]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    public static let javascriptSource = #"""
    {
      "language": "JavaScript",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(const|let|var|function|if|else|elif|while|for|do|switch|case|break|continue|return|new|this|class|extends|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|in|of|yield|delete|void|typeof)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:`[^`]*`|'[^']*'|\\\"[^\\\"]*\\\")"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)(?:^|[^\\\\])\\/\\/[^\\n]*|#\"(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?(?:n)?\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_$]\\w*(?=\\s*\\()"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(String|Number|Boolean|Object|Array|Function|Symbol|undefined|null|Promise|Map|Set|WeakMap|WeakSet|RegExp|Date|Error|JSON|Math|console)\\b"
          ]
        },
        {
          "name": "regex",
          "patterns": [
            "/[^/\\n]*[/igmu]*"
          ]
        }
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

    /// The decoded JavaScript definition. Decoding happens once, lazily.
    public static let javascript: LexerDefinition = {
        do {
            return try LexerDefinition(json: javascriptSource)
        } catch {
            preconditionFailure("Embedded JavaScript lexer definition is invalid: \(error)")
        }
    }()
}
