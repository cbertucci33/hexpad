import Foundation

extension LexerDefinition {

    /// The GNU Make grammar (`.mk`, `Makefile`, `GNUmakefile`).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Make highlights its conditional/directive keywords, `#` comments, and
    /// the three variable forms (`$(NAME)`, `${NAME}`, and automatic variables
    /// such as `$@`). Recipe bodies are shell text, so shell quoting is the
    /// only string spelling that belongs here.
    public static let makefileSource = #"""
    {
      "language": "Makefile",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(?:ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|include|export|unexport|override|vpath)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"[^\"\\n]*\"",
            "'[^'\\n]*'"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)#[^\\n]*"
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
            "\\$\\([^)\\n]+\\)|\\$\\{[^}\\n]+\\}|\\$\\{?[@<^?*]\\}?"
          ]
        }
      ],
      "comments": {
        "linePrefix": "#"
      },
      "brackets": [
        { "open": "(", "close": ")" },
        { "open": "{", "close": "}" }
      ]
    }
    """#

    /// The decoded Makefile definition. Decoding happens once, lazily.
    public static let makefile: LexerDefinition = {
        do {
            return try LexerDefinition(json: makefileSource)
        } catch {
            preconditionFailure("Embedded Makefile lexer definition is invalid: \(error)")
        }
    }()
}
