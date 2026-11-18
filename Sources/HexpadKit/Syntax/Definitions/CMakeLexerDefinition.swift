import Foundation

extension LexerDefinition {

    /// The CMake grammar (CMake 3.x).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// CMake commands and keywords are case-insensitive. Alongside quoted
    /// arguments this grammar recognizes bracket arguments (`[[...]]` and
    /// `[=[...]=]`) and `${...}` variable references. Command names are left to
    /// the keyword rule: a separate "name before parenthesis" rule would
    /// shadow those keywords at the same range.
    public static let cmakeSource = #"""
    {
      "language": "CMake",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(?:cmake_minimum_required|project|set|unset|add_executable|add_library|add_subdirectory|add_custom_command|add_custom_target|target_link_libraries|target_include_directories|target_compile_definitions|find_package|find_program|include|message|if|elseif|else|endif|while|endwhile|foreach|endforeach|function|endfunction|macro|endmacro|return|break|continue|option|install|configure_file|enable_testing|add_test)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\\[=*\\[[\\s\\S]*?\\]=*\\]",
            "\"(?:[^\"\\\\]|\\\\.)*\""
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
            "\\$\\{[^}\\n]+\\}"
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

    /// The decoded CMake definition. Decoding happens once, lazily.
    public static let cmake: LexerDefinition = {
        do {
            return try LexerDefinition(json: cmakeSource)
        } catch {
            preconditionFailure("Embedded CMake lexer definition is invalid: \(error)")
        }
    }()
}
