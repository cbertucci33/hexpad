import Foundation

extension LexerDefinition {

    /// The Clojure grammar (Clojure 1.12).
    ///
    /// The embedded JSON keeps the same format as the migrated definitions:
    /// `Package.swift` declares no `resources:` for `HexpadKit`, so the grammar
    /// ships as a string rather than a loose `.json` file.
    ///
    /// Clojure has no block comment construct; `;` is the only comment form, so
    /// `comments` declares no block delimiters. The `(comment ...)` macro and
    /// the `#_` discard reader macro are ordinary forms, not comment syntax.
    ///
    /// Clojure symbols may contain `-`, `?`, `!`, `*`, `+`, `=`, `<`, and `>`,
    /// so word boundaries are replaced by explicit symbol-character guards.
    public static let clojureSource = #"""
    {
      "language": "Clojure",
      "rules": [
        {
          "name": "keyword",
          "patterns": [
            "(?<![\\w!?*+\\-=<>/])(?:def|defn|defn-|defmacro|defmulti|defmethod|defprotocol|defrecord|deftype|definterface|defonce|definline|fn|let|letfn|loop|recur|if|if-not|if-let|if-some|when|when-let|when-not|when-first|cond|condp|case|do|doseq|dotimes|for|while|try|catch|finally|throw|new|set!|quote|var|ns|require|import|use|refer|refer-clojure|in-ns|monitor-enter|monitor-exit|and|or|not|nil|true|false|some->|some->>|->|->>|as->|cond->|cond->>|doto|binding|with-open|with-local-vars|future|delay|promise|atom|agent|ref|memoize|partial|comp|juxt|complement|constantly|identity|apply|map|reduce|filter|remove|concat|into|assoc|dissoc|get|update|merge|select-keys|keys|vals|count|first|rest|next|seq|cons|list|vector|hash-map|hash-set|sorted-map|sorted-set|range|repeat|repeatedly|take|drop|take-while|drop-while|partition|group-by|sort|sort-by|distinct|flatten|interleave|interpose)(?![\\w!?*+\\-=<>/])"
          ]
        },
        {
          "name": "string",
          "patterns": [
            "\"(?:[^\"\\\\]|\\\\.)*\"|\\\\(?:newline|space|tab|backspace|formfeed|return|u[0-9a-fA-F]{4}|o[0-7]{1,3}|.)"
          ]
        },
        {
          "name": "comment",
          "patterns": [
            "(?m);[^\\n]*"
          ]
        },
        {
          "name": "number",
          "patterns": [
            "\\b(?:0[xX][0-9a-fA-F]+|\\d+/\\d+|\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?[MN]?)\\b"
          ]
        },
        {
          "name": "type",
          "patterns": [
            "\\b(?:String|Long|Integer|Double|Float|Boolean|Character|Object|Number|BigDecimal|BigInteger|Ratio|PersistentVector|PersistentMap|PersistentList|PersistentSet|Atom|Ref|Agent|Keyword|Symbol|Var|IFn|ISeq|IPersistentMap|IPersistentVector|Exception|Throwable)\\b"
          ]
        },
        {
          "name": "function",
          "patterns": [
            "(?<=\\(def )[A-Za-z_*+!?<>=/-][\\w*+!?<>=/-]*",
            "(?<=\\(defn )[A-Za-z_*+!?<>=/-][\\w*+!?<>=/-]*",
            "(?<=\\(defn- )[A-Za-z_*+!?<>=/-][\\w*+!?<>=/-]*",
            "(?<=\\(defmacro )[A-Za-z_*+!?<>=/-][\\w*+!?<>=/-]*",
            "(?<=\\(defonce )[A-Za-z_*+!?<>=/-][\\w*+!?<>=/-]*"
          ]
        }
      ],
      "symbols": [
        { "rule": "function", "kind": "function" }
      ],
      "comments": {
        "linePrefix": ";"
      },
      "brackets": [
        { "open": "{", "close": "}" },
        { "open": "(", "close": ")" },
        { "open": "[", "close": "]" }
      ]
    }
    """#

    /// The decoded Clojure definition. Decoding happens once, lazily.
    public static let clojure: LexerDefinition = {
        do {
            return try LexerDefinition(json: clojureSource)
        } catch {
            preconditionFailure("Embedded Clojure lexer definition is invalid: \(error)")
        }
    }()
}
