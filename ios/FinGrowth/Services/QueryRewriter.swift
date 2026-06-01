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
        case email
        case ssn
        case phone

        // Three-tier classification (V9-01) that drives what the rewriter removes
        // (V9-02). Tier 1 identity is always stripped; tier 2 portfolio specifics
        // (share counts) are preserved; tier 3 sensitive financials follow the
        // user's privacy level. Brokerage is treated as identity: it names the
        // institution holding your account, carries no analytical value, and
        // pairs with identity — so it's hard-walled like other tier 1 fields.
        var tier: PrivacyTier {
            switch self {
            case .accountNumber, .holderName, .brokerage, .email, .ssn, .phone:
                return .identity
            case .quantity:
                return .portfolioSpecific
            case .costBasis, .amount, .liability:
                return .sensitiveFinancial
            }
        }
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

    // ``privacyLevel`` governs tier 3 (sensitive financial) handling (V9-02):
    // at the default minimal/moderate it's generalized away; only when the user
    // opts into `.detailed` are exact tier-3 figures preserved. Tier 1 identity
    // is always stripped and tier 2 portfolio specifics (share counts, tickers)
    // are always preserved, regardless of level.
    func rewrite(
        query: String,
        ledger: PrivateLedger? = nil,
        privacyLevel: PortfolioPrivacyLevel = .moderate
    ) async -> RewrittenQuery {
        let (deterministicText, substitutions) = Self.applyRules(
            to: query, ledger: ledger, privacyLevel: privacyLevel
        )

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
           Self.isSafe(paraphrase, substitutions: substitutions, ledger: ledger),
           // V9-02: a fluent paraphrase must also *keep* the tier-2 specifics the
           // deterministic rewrite preserved — dropping "500 shares" would defeat
           // the whole point. Otherwise fall back to the deterministic text.
           Self.preservesTier2(paraphrase, of: deterministicText) {
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
        intent. Keep ticker symbols and share counts — they describe a portfolio, \
        not a person. Remove only personal identity (names, account numbers, \
        brokerage names) and personal dollar figures (cost basis, account \
        balances, debts). Reply with only the rewritten question.

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
            case .accountNumber, .email, .ssn, .phone:
                // The whole token is the secret — forbid it verbatim so a
                // paraphrase can't re-echo a typed email / SSN / phone / acct.
                fragments.insert(sub.original.lowercased())
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

    // MARK: - Tier 2 preservation (V9-02)

    // The tier-2 specifics (share counts, ticker symbols) the cloud is allowed —
    // and expected — to see. Extracted from the *deterministic* rewrite, which
    // already preserved them, so a model paraphrase that drops any can be
    // rejected in favor of the deterministic output.
    static func tier2Fragments(in text: String) -> Set<String> {
        var out: Set<String> = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Share counts: the digits in "<n> shares".
        for match in shareCountRegex.matches(in: text, range: full) {
            let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if !digits.isEmpty { out.insert(digits.lowercased()) }
        }
        // Ticker-like uppercase tokens (AAPL, BRK.B), minus non-ticker acronyms
        // so a fluent rewrite of a metric (e.g. "RSI") isn't wrongly rejected.
        for match in tickerRegex.matches(in: text, range: full) {
            let token = ns.substring(with: match.range)
            if !tickerAcronymStopwords.contains(token) { out.insert(token.lowercased()) }
        }
        return out
    }

    // True iff ``paraphrase`` retains every tier-2 specific present in ``source``.
    static func preservesTier2(_ paraphrase: String, of source: String) -> Bool {
        let lowered = paraphrase.lowercased()
        return tier2Fragments(in: source).allSatisfy { lowered.contains($0) }
    }

    private static let shareCountRegex = makeRegex(#"\b(\d[\d,]*)\s+shares?\b"#)
    // Case-sensitive (uppercase only) so it matches tickers, not lowercase prose.
    private static let tickerRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\b[A-Z]{1,5}(?:\.[A-Z])?\b"#)
    }()
    // Common finance acronyms that look like tickers but aren't holdings; a
    // paraphrase may legitimately reword these, so they aren't required.
    private static let tickerAcronymStopwords: Set<String> = [
        "RSI", "MACD", "ETF", "EPS", "IPO", "CEO", "CFO", "SEC", "GDP",
        "PE", "ATH", "YOY", "USD", "AI", "I", "A", "ROI", "EBITDA",
    ]

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
        ledger: PrivateLedger?,
        privacyLevel: PortfolioPrivacyLevel
    ) -> (text: String, substitutions: [QuerySubstitution]) {
        var text = query
        var subs: [QuerySubstitution] = []

        // 1. Exact ledger PII (account number / holder) — tier 1, always.
        for (raw, replacement, kind) in ledgerSecrets(ledger) {
            applyLiteral(raw, replacement: replacement, type: kind, in: &text, subs: &subs)
        }

        // 2. Tier 2 (share counts, tickers): preserved (V9-02). The old quantity
        //    generalization is gone — "500 shares of TSLA" describes a portfolio,
        //    not a person, and is exactly the analytical detail the cloud needs.

        // 3. Context-specific pattern rules, applied by tier (V9-02):
        //      * tier 1 (brokerage) — always.
        //      * tier 3 (cost basis, balances, debts) — only when the user
        //        hasn't opted into sharing exact sensitive financials.
        let discloseTier3 = PrivacyTier.sensitiveFinancial.isDisclosed(at: privacyLevel)
        for rule in rules {
            switch rule.type.tier {
            case .identity:
                apply(rule, in: &text, subs: &subs)
            case .sensitiveFinancial where !discloseTier3:
                apply(rule, in: &text, subs: &subs)
            default:
                break  // tier 2, or opted-in tier 3 → preserved
            }
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
        // Tier 1 identity typed directly into a query (no ledger match needed).
        // These are incidental identity tokens (V9-02 AC2) that must never reach
        // the cloud, so they're stripped at any privacy level. Patterns are
        // high-precision to avoid eating tickers / share counts / prices.
        Rule(
            regex: makeRegex(#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
            replacement: "an email address",
            type: .email
        ),
        Rule(
            regex: makeRegex(#"\b\d{3}-\d{2}-\d{4}\b"#),
            replacement: "a personal ID",
            type: .ssn
        ),
        Rule(
            regex: makeRegex(#"(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]\d{3}[-.\s]\d{4}\b"#),
            replacement: "a phone number",
            type: .phone
        ),
        // An account number stated freeform ("account X12345678", "acct #4471203").
        // Requires the account keyword and a digit-bearing 6+ token so it can't
        // swallow "account balance" or a bare share count.
        Rule(
            regex: makeRegex(#"\b(?:account|acct)\s*#?\s*(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{6,}\b"#),
            replacement: "my account",
            type: .accountNumber
        ),
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
}
