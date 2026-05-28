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

struct QuerySubstitution: Equatable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
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
           Self.isSafe(paraphrase, substitutions: substitutions, ledger: ledger) {
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

    // A paraphrase is safe only if it reintroduces none of the *sensitive
    // fragments* of what we replaced — not merely the exact original phrase. A
    // model that drops "bought at" but keeps "$280", or rewrites "Fidelity
    // account" to "Fidelity portfolio", must still be rejected.
    static func isSafe(_ text: String, substitutions: [QuerySubstitution], ledger: PrivateLedger?) -> Bool {
        let lowered = text.lowercased()
        return forbiddenFragments(substitutions: substitutions, ledger: ledger)
            .allSatisfy { !lowered.contains($0) }
    }

    // Sensitive cores extracted from each substitution: numeric runs (share
    // counts, dollar amounts, account digits) and proper-noun words (brokerage
    // names, holder-name tokens), plus the raw ledger PII values.
    static func forbiddenFragments(
        substitutions: [QuerySubstitution],
        ledger: PrivateLedger?
    ) -> Set<String> {
        var fragments: Set<String> = []

        func addNumbers(_ source: String) {
            let ns = source as NSString
            let matches = numberRegex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let digits = ns.substring(with: match.range).replacingOccurrences(of: ",", with: "")
                if digits.count >= 2 { fragments.insert(digits.lowercased()) }
            }
        }
        func addProperWords(_ source: String, minLength: Int) {
            for token in source.split(whereSeparator: { !$0.isLetter }) where token.count >= minLength {
                let word = token.lowercased()
                if !fragmentStopwords.contains(word) { fragments.insert(word) }
            }
        }

        for sub in substitutions {
            addNumbers(sub.original)
            switch sub.type {
            case .brokerage, .holderName: addProperWords(sub.original, minLength: 4)
            case .accountNumber: fragments.insert(sub.original.lowercased())
            default: break
            }
        }
        if let account = ledger?.accountNumber, !account.isEmpty {
            fragments.insert(account.lowercased())
            addNumbers(account)
        }
        if let holder = ledger?.accountHolder, !holder.isEmpty {
            fragments.insert(holder.lowercased())
            addProperWords(holder, minLength: 3)
        }
        return fragments
    }

    private static let numberRegex = makeRegex(#"\d[\d,]*"#)
    // Generic words that may appear in an `original` but aren't themselves PII.
    private static let fragmentStopwords: Set<String> = [
        "account", "shares", "share", "portfolio", "with", "bought",
        "given", "loans", "loan", "debt", "student", "savings", "balance",
    ]

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

        // 2. Share counts (magnitude-aware).
        applyQuantityRule(in: &text, subs: &subs)

        // 3. Context-specific pattern rules.
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
        guard !raw.isEmpty else { return }
        var recorded = false
        // Replace every occurrence — "Compare X12345678 with X12345678" must not
        // leave the second copy behind. Search resumes after each replacement so
        // we never rescan the inserted text.
        var searchStart = text.startIndex
        while let range = text.range(of: raw, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let original = String(text[range])
            text.replaceSubrange(range, with: replacement)
            if !recorded {
                subs.append(QuerySubstitution(original: original, replacement: replacement, type: type))
                recorded = true
            }
            searchStart = text.range(of: replacement, range: range.lowerBound..<text.endIndex)?.upperBound
                ?? text.endIndex
        }
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

    // Dollar amounts are generalized only in a *personal* financial context
    // (debts, cost basis, portfolio/savings balances) — never blanket. A public
    // market fact like "Apple's $110B buyback" must pass through unchanged, per
    // the no-PII pass-through criterion. Ordered so specific contexts win.
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
            regex: makeRegex(#"(?:Fidelity|Charles\s+Schwab|Schwab|Robinhood|Vanguard|E\*?TRADE)(?:\s+account)?"#),
            replacement: "portfolio",
            type: .brokerage
        ),
        // Personal balance stated as "$X in portfolio/savings/..." …
        Rule(
            regex: makeRegex(#"\$\s?\d[\d,]*\.?\d*\s*[KkMm]?\s+(?:in\s+)?(?:portfolio|savings|cash|retirement|income|salary)\b"#),
            replacement: "an undisclosed amount",
            type: .amount
        ),
        // … or "portfolio/savings/net worth (of/worth/is) $X".
        Rule(
            regex: makeRegex(#"(?:portfolio|savings|balance|net\s+worth)\s+(?:of\s+|worth\s+|is\s+)?\$\s?\d[\d,]*\.?\d*\s*[KkMm]?"#),
            replacement: "an undisclosed amount",
            type: .amount
        ),
    ]

    // Share counts are generalized but not over-characterized: only a clearly
    // large holding becomes "concentrated"; a handful of shares stays a neutral
    // "a position" so small-position intent isn't distorted.
    private static let concentratedThreshold = 100
    private static let quantityRegex = makeRegex(#"\b(\d[\d,]*)\s+shares?\b"#)

    private static func applyQuantityRule(in text: inout String, subs: inout [QuerySubstitution]) {
        let matches = quantityRegex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard !matches.isEmpty else { return }
        // Replace right-to-left so earlier match ranges stay valid.
        var collected: [QuerySubstitution] = []
        for match in matches.reversed() {
            let ns = text as NSString
            let original = ns.substring(with: match.range)
            let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            let count = Int(digits) ?? 0
            let replacement = count >= concentratedThreshold ? "concentrated position" : "a position"
            collected.append(QuerySubstitution(original: original, replacement: replacement, type: .quantity))
            if let range = Range(match.range, in: text) {
                text.replaceSubrange(range, with: replacement)
            }
        }
        subs.append(contentsOf: collected.reversed())
    }
}
