import Foundation

/// Converts data-driven definitions into the compiled rule form that
/// `SyntaxTokenizer` consumes.
///
/// Both the data-driven and legacy paths go through this loader, so rule
/// compilation, token type mapping, and invalid-pattern handling stay
/// identical. The tokenizer caches the resulting rules per language.
enum LexerDefinitionLoader {

    /// Compiles a definition's rules in declaration (priority) order.
    ///
    /// Unknown rule names and patterns that fail to compile are skipped, which
    /// matches the legacy dictionary behavior.
    static func compiledRules(from definition: LexerDefinition) -> [SyntaxTokenizer.CompiledRule] {
        definition.rules.flatMap { rule -> [SyntaxTokenizer.CompiledRule] in
            guard let type = SyntaxTokenizer.tokenTypeByName[rule.name] else { return [] }
            return rule.patterns.compactMap { pattern in
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    return nil
                }
                return SyntaxTokenizer.CompiledRule(type: type, regex: regex)
            }
        }
    }

    /// Compiles a legacy `rule name -> regex patterns` table.
    ///
    /// The production tokenizer no longer uses this path; it is retained so the
    /// lexer-definition tests can tokenize a sample with the pre-migration rule
    /// tables and compare the result against the data-driven definitions.
    ///
    /// Dictionary iteration order is not stable, so rule names are sorted to
    /// keep tie-breaking deterministic across runs and processes.
    static func compiledRules(fromLegacyTable ruleTable: [String: [String]]) -> [SyntaxTokenizer.CompiledRule] {
        ruleTable.keys.sorted().flatMap { name -> [SyntaxTokenizer.CompiledRule] in
            guard let type = SyntaxTokenizer.tokenTypeByName[name],
                  let patterns = ruleTable[name] else { return [] }
            return patterns.compactMap { pattern in
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    return nil
                }
                return SyntaxTokenizer.CompiledRule(type: type, regex: regex)
            }
        }
    }
}
