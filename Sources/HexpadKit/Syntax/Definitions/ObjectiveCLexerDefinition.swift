import Foundation

extension LexerDefinition {

    /// The Objective-C grammar (`.mm`).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// `.m` is claimed by MATLAB earlier in `Language.fromFileName`, so this
    /// language owns only the unambiguous `.mm` spelling. The rules cover `//`
    /// and `/* */` comments, `@"..."` (and plain C) strings, `#import`/`#include`
    /// preprocessor lines, NS-prefixed Foundation types, and the bracket pairs
    /// ObjC actually uses — including `<...>` for generics and protocols.
    public static let objectiveCSource = #"""
    {
      "language": "Objective-C",
      "rules": [
        {
          "name": "comment",
          "patterns": [
            "//[^\\n]*",
            "/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "@\"(?:[^\"\\\\]|\\\\.)*\"",
            "\"(?:[^\"\\\\]|\\\\.)*\""
          ]
        },
        {
          "name": "keyword",
          "patterns": [
            "(?m)^[ \\t]*#(?:import|include|define|pragma|ifdef|ifndef|endif|if|else|elif|undef)\\b[^\\n]*",
            "@(?:interface|implementation|protocol|end|property|synthesize|dynamic|selector|class|autoreleasepool|try|catch|finally|throw)\\b",
            "\\b(?:if|else|for|while|do|switch|case|default|break|continue|return|void|int|char|float|double|long|short|unsigned|signed|const|static|struct|enum|union|typedef|sizeof|nil|YES|NO|self|super|in|out|inout)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\bNS[A-Z][A-Za-z0-9_]*\\b"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|\\d+(?:\\.\\d+)?)\\b"
          ]
        }
      ],
      "comments": {
        "linePrefix": "//",
        "blockStart": "/*",
        "blockEnd": "*/"
      },
      "brackets": [
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" },
        { "open": "{", "close": "}" },
        { "open": "<", "close": ">" }
      ]
    }
    """#

    /// The decoded Objective-C definition. Decoding happens once, lazily.
    public static let objectivec: LexerDefinition = {
        do {
            return try LexerDefinition(json: objectiveCSource)
        } catch {
            preconditionFailure("Embedded Objective-C lexer definition is invalid: \(error)")
        }
    }()
}
