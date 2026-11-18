import Foundation

extension LexerDefinition {

    /// The PowerShell grammar (PowerShell 7, `.ps1` and `.psm1`).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Beyond the control-flow keywords, PowerShell's verb-noun cmdlets are
    /// highlighted as keywords and `$variables` get their own rule. Double
    /// quoted strings honor backtick escapes, and both `#` line comments and
    /// `<# ... #>` block comments are declared.
    public static let powershellSource = #"""
    {
      "language": "PowerShell",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(?:if|elseif|else|for|foreach|while|do|switch|case|default|break|continue|return|throw|try|catch|finally|function|filter|param|begin|process|end|class|enum|in|from|using|namespace)\\b",
            "(?i)\\b(?:Get|Set|New|Remove|Write|Read|Add|Clear|Copy|Move|Join|Split|Select|Where|ForEach|Sort|Measure|Test|Import|Export|Invoke|Start|Stop|Find|Format|Out|ConvertTo|ConvertFrom|Update|Rename|Restart|Enable|Disable|Assert|Compare|Register|Unregister)-[a-zA-Z][\\w-]*\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "@\\\"[\\s\\S]*?\\\"@",
            "@'[\\s\\S]*?'@",
            "\"(?:[^\"`]|`.)*\"",
            "'[^']*'"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)#[^\\n]*|(?ms)<#[\\s\\S]*?#>"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?\\b"
          ]
        },
        {
          "name": "variable",
          "patterns": [
            "\\$[a-zA-Z_][\\w:]*|\\$_|\\$\\{[^}\\n]+\\}"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "(?<=function )[a-zA-Z_][\\w-]*"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": "#",
        "blockStart": "<#",
        "blockEnd": "#>"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded PowerShell definition. Decoding happens once, lazily.
    public static let powershell: LexerDefinition = {
        do {
            return try LexerDefinition(json: powershellSource)
        } catch {
            preconditionFailure("Embedded PowerShell lexer definition is invalid: \(error)")
        }
    }()
}
