import Foundation

extension LexerDefinition {

    /// The unified-diff grammar (`.diff`, `.patch`).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// A diff's meaning is carried entirely by the first character of each
    /// line, so every rule is line-anchored. There is no language-wide comment,
    /// string, or number construct to describe and no structural bracket pair,
    /// hence no `comments` and no `brackets` metadata. The three token types
    /// are reused for the three line classes: additions map to `string`,
    /// removals to `comment`, and headers to `keyword` (the closest supported
    /// types). The second character must differ from the first so the `---` and
    /// `+++` file banners are not mistaken for a hunk line.
    public static let diffSource = #"""
    {
      "language": "Diff",
      "rules": [
        {
          "name": "string",
          "patterns": [
            "(?m)^\\+[^+\\n][^\\n]*"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)^-[^-\\n][^\\n]*"
          ]
        },
        {
          "name": "keyword",
          "patterns": [
            "(?m)^@@.*@@[^\\n]*",
            "(?m)^Index: [^\\n]*",
            "(?m)^diff [^\\n]*"
          ]
        }
      ]
    }
    """#

    /// The decoded Diff definition. Decoding happens once, lazily.
    public static let diff: LexerDefinition = {
        do {
            return try LexerDefinition(json: diffSource)
        } catch {
            preconditionFailure("Embedded Diff lexer definition is invalid: \(error)")
        }
    }()
}
