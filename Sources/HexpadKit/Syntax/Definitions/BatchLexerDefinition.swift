import Foundation

extension LexerDefinition {

    /// The Batch grammar (Windows `cmd.exe` batch files).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// cmd.exe is case-insensitive, so both keywords and `rem` comments match
    /// in any case. A `::` line is a label that cmd.exe skips, so it highlights
    /// as a comment too. Batch has no structural bracket pairs worth declaring
    /// (parentheses only group commands in a block), so `brackets` stays empty.
    public static let batchSource = #"""
    {
      "language": "Batch",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(?:echo|set|setlocal|endlocal|if|else|for|in|do|call|goto|exit|shift|pause|title|pushd|popd|cd)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"[^\\n\"]*\""
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?im)^[ \\t]*(?:rem(?:\\b[^\\n]*)?|::[^\\n]*)"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|\\d+)\\b"
          ]
        },
        {
          "name": "variable",
          "patterns": [
            "%[a-zA-Z_][\\w]*%|%[0-9]|%%[a-zA-Z_][\\w]*"
          ]
        }
      ],
      "comments": {
        "linePrefix": "rem "
      },
      "brackets": []
    }
    """#

    /// The decoded Batch definition. Decoding happens once, lazily.
    public static let batch: LexerDefinition = {
        do {
            return try LexerDefinition(json: batchSource)
        } catch {
            preconditionFailure("Embedded Batch lexer definition is invalid: \(error)")
        }
    }()
}
