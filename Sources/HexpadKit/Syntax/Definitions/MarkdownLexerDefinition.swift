import Foundation

extension LexerDefinition {

    /// The Markdown grammar, migrated from
    /// `SyntaxTokenizer.languageRules[.markdown]`.
    ///
    /// Like the JSON definition, the source of truth is the JSON text below
    /// rather than a `.json` resource file: `Package.swift` declares no
    /// `resources:` for `HexpadKit`, so a loose file would be an unhandled
    /// resource and would not ship in the built module. Keeping the grammar as
    /// an embedded string preserves the data-driven format while staying inside
    /// the Syntax scope.
    ///
    /// Markdown has no line-comment form; inline HTML comments are valid and
    /// are the only comment syntax, so they populate the block-comment
    /// metadata. The foldable unit is a heading section rather than a bracket
    /// pair, so it is declared in `foldableRangeRules` (kind
    /// `headingSection`) and `brackets` stays empty.
    public static let markdownSource = #"""
    {
      "language": "Markdown",
      "rules": [
        {
          "name": "heading",
          "patterns": [
            "(?m)^#{1,6}\\s.*"
          ]
        },
        {
          "name": "bold",
          "patterns": [
            "\\*\\*[^*]+\\*\\*|##[^#]+##"
          ]
        },
        {
          "name": "italic",
          "patterns": [
            "\\*[^*]+\\*"
          ]
        },
        {
          "name": "code",
          "patterns": [
            "`[^`]+`"
          ]
        },
        {
          "name": "link",
          "patterns": [
            "\\[.+?\\]\\(.+?\\)"
          ]
        },
        {
          "name": "image",
          "patterns": [
            "\\[[^\\]]*\\]\\([^\\)]*\\)"
          ]
        },
        {
          "name": "blockquote",
          "patterns": [
            "(?m)^\\s*>.*"
          ]
        },
        {
          "name": "list",
          "patterns": [
            "(?m)^\\s*[-*+]\\s"
          ]
        },
        {
          "name": "hrule",
          "patterns": [
            "(?m)^\\s*[-*_]{3,}\\s*"
          ]
        }
      ],
      "comments": {
        "blockStart": "<!--",
        "blockEnd": "-->"
      },
      "foldableRangeRules": [
        {
          "kind": "headingSection",
          "startPattern": "(?m)^#{1,6}\\s.*"
        }
      ]
    }
    """#

    /// The decoded Markdown definition. Decoding happens once, lazily.
    public static let markdown: LexerDefinition = {
        do {
            return try LexerDefinition(json: markdownSource)
        } catch {
            preconditionFailure("Embedded Markdown lexer definition is invalid: \(error)")
        }
    }()
}
