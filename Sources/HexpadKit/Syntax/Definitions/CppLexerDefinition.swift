import Foundation

extension LexerDefinition {

    /// The C++ grammar (C++20).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    public static let cppSource = #"""
    {
      "language": "C++",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "\\b(alignas|alignof|and|and_eq|asm|auto|bitand|bitor|bool|break|case|catch|char|char8_t|char16_t|char32_t|class|compl|concept|const|consteval|constexpr|constinit|const_cast|continue|co_await|co_return|co_yield|decltype|default|delete|do|double|dynamic_cast|else|enum|explicit|export|extern|false|float|for|friend|goto|if|inline|int|long|mutable|namespace|new|noexcept|not|not_eq|nullptr|operator|or|or_eq|private|protected|public|register|reinterpret_cast|requires|return|short|signed|sizeof|static|static_assert|static_cast|struct|switch|template|this|thread_local|throw|true|try|typedef|typeid|typename|union|unsigned|using|virtual|void|volatile|wchar_t|while|xor|xor_eq)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "(?:R\"\\([\\s\\S]*?\\)\"|\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*')"
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
            "\\b(?:0[xX][0-9a-fA-F']+|0[bB][01']+|\\d[\\d']*(?:\\.\\d*)?(?:[eE][+-]?\\d+)?)(?:[uUlLfF]|ll|LL|ull|ULL)*\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(std|string|wstring|string_view|vector|array|list|forward_list|deque|map|unordered_map|set|unordered_set|multimap|multiset|pair|tuple|optional|variant|any|unique_ptr|shared_ptr|weak_ptr|function|thread|mutex|size_t|ptrdiff_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|ostream|istream|iostream|fstream|stringstream)\\b"
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

    /// The decoded C++ definition. Decoding happens once, lazily.
    public static let cpp: LexerDefinition = {
        do {
            return try LexerDefinition(json: cppSource)
        } catch {
            preconditionFailure("Embedded C++ lexer definition is invalid: \(error)")
        }
    }()
}
