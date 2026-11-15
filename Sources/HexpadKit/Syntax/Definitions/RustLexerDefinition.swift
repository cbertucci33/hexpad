import Foundation

extension LexerDefinition {

    /// The Rust grammar (Rust 2021 edition).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let rustSource = #"""
    {
      "language": "Rust",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(as|async|await|become|box|break|const|continue|crate|do|dyn|else|enum|extern|false|final|fn|for|if|impl|in|let|loop|macro|macro_rules|match|mod|move|mut|override|priv|pub|ref|return|self|Self|static|struct|super|trait|true|try|type|typeof|union|unsafe|unsized|use|virtual|where|while|yield)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:r#*\"[\\s\\S]*?\"#*|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'(?:[^'\\\\]|\\\\.)*')"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)//[^\\n]*|(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)(?:[iu](?:8|16|32|64|128|size)|f(?:32|64))?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(bool|char|str|i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f32|f64|String|Vec|Option|Result|Box|Rc|Arc|RefCell|Cell|HashMap|HashSet|BTreeMap|BTreeSet|VecDeque|Cow|Path|PathBuf|OsStr|OsString|CString|CStr)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_]\\w*(?=\\s*\\()"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
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

    /// The decoded Rust definition. Decoding happens once, lazily.
    public static let rust: LexerDefinition = {
        do {
            return try LexerDefinition(json: rustSource)
        } catch {
            preconditionFailure("Embedded Rust lexer definition is invalid: \(error)")
        }
    }()
}
