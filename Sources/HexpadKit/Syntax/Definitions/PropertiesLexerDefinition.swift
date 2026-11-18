import Foundation

extension LexerDefinition {

    /// The Java `.properties` grammar (`.properties`).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// A properties file is a flat list of `key=value` (or `key:value`) entries
    /// with `#`/`!` comment lines. Keys get the `variable` type, values the
    /// `string` type, and both comment markers share one rule. There is no
    /// bracket structure and no number construct worth a separate rule, so the
    /// grammar stops there rather than inventing one.
    public static let propertiesSource = #"""
    {
      "language": "Properties",
      "rules": [
        {
          "name": "comment",
          "patterns": [
            "(?m)^[ \\t]*[!#][^\\n]*"
          ]
        },
        {
          "name": "variable",
          "patterns": [
            "(?m)^[A-Za-z_][A-Za-z0-9_.\\-]*(?=[ \\t]*[=:])"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?<==)[ \\t]*[^\\n]+"
          ]
        }
      ],
      "comments": {
        "linePrefix": "#"
      },
      "brackets": []
    }
    """#

    /// The decoded Properties definition. Decoding happens once, lazily.
    public static let properties: LexerDefinition = {
        do {
            return try LexerDefinition(json: propertiesSource)
        } catch {
            preconditionFailure("Embedded Properties lexer definition is invalid: \(error)")
        }
    }()
}
