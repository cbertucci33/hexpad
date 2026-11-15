import Foundation

extension LexerDefinition {

    /// The SQL grammar (ANSI SQL, with the common dialect keywords).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Keywords and type names are case-insensitive, matching SQL's own
    /// case-folding rules. Quoted identifiers (`"name"`) are highlighted as
    /// strings because the tokenizer has no dedicated identifier token type.
    public static let sqlSource = #"""
    {
      "language": "SQL",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|ALTER|DROP|TRUNCATE|TABLE|VIEW|INDEX|DATABASE|SCHEMA|JOIN|INNER|LEFT|RIGHT|FULL|OUTER|CROSS|ON|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|INTERSECT|EXCEPT|ALL|DISTINCT|AS|AND|OR|NOT|NULL|IS|IN|LIKE|ILIKE|BETWEEN|EXISTS|CASE|WHEN|THEN|ELSE|END|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|UNIQUE|CHECK|CONSTRAINT|BEGIN|COMMIT|ROLLBACK|TRANSACTION|GRANT|REVOKE|WITH|RETURNING|ASC|DESC|IF|EXPLAIN|ANALYZE|VACUUM|CASCADE|RESTRICT|ADD|COLUMN|RENAME|USE)\\b"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\""
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m)--[^\\n]*|(?ms)/\\*[\\s\\S]*?\\*/"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "(?i)\\b(INT|INTEGER|SMALLINT|BIGINT|TINYINT|DECIMAL|NUMERIC|FLOAT|REAL|DOUBLE|BOOLEAN|BOOL|CHAR|VARCHAR|NVARCHAR|TEXT|DATE|TIME|TIMESTAMP|DATETIME|INTERVAL|BLOB|CLOB|JSON|JSONB|UUID|XML|SERIAL|BIGSERIAL|MONEY)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "\\b[a-zA-Z_]\\w*(?=\\s*\\()"
          ]
        }
      ],
      "comments": {
        "linePrefix": "--",
        "blockStart": "/*",
        "blockEnd": "*/"
      },
      "brackets": [
        { "open": "(", "close": ")" }
      ]
    }
    """#

    /// The decoded SQL definition. Decoding happens once, lazily.
    public static let sql: LexerDefinition = {
        do {
            return try LexerDefinition(json: sqlSource)
        } catch {
            preconditionFailure("Embedded SQL lexer definition is invalid: \(error)")
        }
    }()
}
