import Foundation

// Semantic query rewriter (P5-04).
//
// Unlike token scrubbing, this preserves the analytical question while
// replacing private specifics (share counts, dollar amounts, cost basis,
// brokerage names, personal liabilities, and any ledger PII) with generalized
// equivalents that are safe to send to the cloud. A query with no private
// specifics passes through unchanged.
//
// The deterministic rule engine below is the verifiable core and the fallback;
// when a real on-device Gemma model is loaded it can supply a smoother
// paraphrase, accepted only if it doesn't reintroduce any substituted specific.

struct QuerySubstitution: Equatable, Sendable {
    enum Kind: String, Sendable {
        case quantity
        case costBasis
        case amount
        case brokerage
        case liability
        case accountNumber
        case holderName
    }

    let original: String
    let replacement: String
    let type: Kind
}

struct RewrittenQuery: Equatable, Sendable {
    let originalText: String
    let rewrittenText: String
    let substitutions: [QuerySubstitution]
    let confidenceScore: Double

    var changed: Bool { rewrittenText != originalText }
}

struct QueryRewriter: Sendable {
    let gemma: GemmaService?

    init(gemma: GemmaService? = nil) {
        self.gemma = gemma
    }

    func rewrite(query: String, ledger: PrivateLedger? = nil) async -> RewrittenQuery {
        let (deterministicText, substitutions) = Self.applyRules(to: query, ledger: ledger)

        // No private specifics → pass through unchanged (acceptance: clean
        // queries are untouched).
        guard !substitutions.isEmpty else {
            return RewrittenQuery(
                originalText: query,
                rewrittenText: query,
                substitutions: [],
                confidenceScore: 1.0
            )
        }

        // Real on-device model: prefer a fluent paraphrase, but only if it
        // doesn't leak any specific we just generalized away.
        if let gemma, await gemma.usesRealModel, await gemma.isReady,
           let paraphrase = await modelParaphrase(of: query, gemma: gemma),
           Self.isSafe(paraphrase, against: substitutions) {
            return RewrittenQuery(
                originalText: query,
                rewrittenText: paraphrase,
                substitutions: substitutions,
                confidenceScore: 0.9
            )
        }

        return RewrittenQuery(
            originalText: query,
            rewrittenText: deterministicText,
            substitutions: substitutions,
            confidenceScore: 0.75
        )
    }

    // MARK: - Gemma paraphrase (real model only)

    private func modelParaphrase(of query: String, gemma: GemmaService) async -> String? {
        let prompt = """
        Rewrite the investment question below so it preserves the analytical \
        intent but removes all personal specifics (share counts, dollar amounts, \
        brokerage names, personal debts). Reply with only the rewritten question.

        Question: \(query)
        """
        var output = ""
        let stream = await gemma.generate(prompt: prompt, maxTokens: 96)
        for await token in stream {
            output += token
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // A paraphrase is safe only if it reintroduces none of the original
    // (private) substring we replaced.
    static func isSafe(_ text: String, against substitutions: [QuerySubstitution]) -> Bool {
        let lowered = text.lowercased()
        return substitutions.allSatisfy { !lowered.contains($0.original.lowercased()) }
    }

    // MARK: - Deterministic rule engine

    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        let type: QuerySubstitution.Kind
    }

    private static func applyRules(
        to query: String,
        ledger: PrivateLedger?
    ) -> (text: String, substitutions: [QuerySubstitution]) {
        var text = query
        var subs: [QuerySubstitution] = []

        // 1. Exact ledger PII (account number / holder) — most sensitive first.
        for (raw, replacement, kind) in ledgerSecrets(ledger) {
            applyLiteral(raw, replacement: replacement, type: kind, in: &text, subs: &subs)
        }

        // 2. Pattern rules, ordered so specific contexts win over the generic
        //    dollar-amount catch-all.
        for rule in rules {
            apply(rule, in: &text, subs: &subs)
        }
        return (text, subs)
    }

    private static func ledgerSecrets(
        _ ledger: PrivateLedger?
    ) -> [(String, String, QuerySubstitution.Kind)] {
        guard let ledger else { return [] }
        var out: [(String, String, QuerySubstitution.Kind)] = []
        if let account = ledger.accountNumber, !account.isEmpty {
            out.append((account, "my account", .accountNumber))
        }
        if let holder = ledger.accountHolder, !holder.isEmpty {
            out.append((holder, "the investor", .holderName))
        }
        return out
    }

    private static func applyLiteral(
        _ raw: String,
        replacement: String,
        type: QuerySubstitution.Kind,
        in text: inout String,
        subs: inout [QuerySubstitution]
    ) {
        guard !raw.isEmpty,
              let range = text.range(of: raw, options: .caseInsensitive) else { return }
        let original = String(text[range])
        text.replaceSubrange(range, with: replacement)
        subs.append(QuerySubstitution(original: original, replacement: replacement, type: type))
    }

    private static func apply(_ rule: Rule, in text: inout String, subs: inout [QuerySubstitution]) {
        let ns = text as NSString
        let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        for match in matches {
            subs.append(QuerySubstitution(
                original: ns.substring(with: match.range),
                replacement: rule.replacement,
                type: rule.type
            ))
        }
        text = rule.regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
        )
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // Ordered: liability and cost-basis contexts are matched before the generic
    // dollar-amount rule so they get the more specific generalization + type.
    private static let rules: [Rule] = [
        Rule(
            regex: makeRegex(#"\$\s?\d[\d,]*\.?\d*\s*[KkMm]?\s+(?:in\s+)?(?:student\s+loans?|loans?|debt|mortgages?)"#),
            replacement: "significant debt obligations",
            type: .liability
        ),
        Rule(
            regex: makeRegex(#"(?:bought|purchased|paid|acquired)\s+(?:at|for)\s+\$\s?\d[\d,]*\.?\d*\s*[KkMm]?"#),
            replacement: "with an undisclosed cost basis",
            type: .costBasis
        ),
        Rule(
            regex: makeRegex(#"\b\d[\d,]*\s+shares?\b"#),
            replacement: "concentrated position",
            type: .quantity
        ),
        Rule(
            regex: makeRegex(#"(?:Fidelity|Charles\s+Schwab|Schwab|Robinhood|Vanguard|E\*?TRADE)(?:\s+account)?"#),
            replacement: "portfolio",
            type: .brokerage
        ),
        Rule(
            regex: makeRegex(#"\$\s?\d[\d,]*\.?\d*\s*[KkMm]?"#),
            replacement: "an undisclosed amount",
            type: .amount
        ),
    ]
}
