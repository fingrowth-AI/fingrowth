import Foundation

// Local response recontextualization (P5-08).
//
// A cloud analysis is computed from the *anonymized* profile we sent, so it
// can only speak in generalities: "your concentrated tech allocation", "a
// tech-heavy portfolio". This module maps those generalized references back to
// the user's actual holdings from the on-device PrivateLedger — turning
// "concentrated tech allocation" into "500 shares of AAPL and 200 shares of
// MSFT".
//
// Three invariants, straight from the design acceptance criteria:
//   * Additive only — the original cloud analysis text is never modified. The
//     mapping is surfaced as a separate "Personalized context" section.
//   * Pass-through — a response with no portfolio reference enriches to nil, so
//     callers render the cloud analysis untouched.
//   * Zero network — everything here reads the local ledger. The optional Gemma
//     smoothing pass is on-device inference; no specifics ever transit the wire.

struct PersonalizedContext: Equatable, Sendable {
    // Section heading shown above the mapped specifics.
    static let title = "Personalized context"

    // One or more lines mapping generalized references to concrete holdings.
    let lines: [String]
    // The specific tickers surfaced in `lines`.
    let tickers: [String]
    // The exact per-holding phrases asserted ("500 shares of AAPL"). Used to
    // validate that an optional model paraphrase preserved each holding's count
    // *and* ticker as a unit — never just the tokens independently.
    let factPhrases: [String]
    // Provenance note — these specifics were resolved on-device and never left.
    let note: String

    static let onDeviceNote = "Matched on-device from your private ledger — these specifics never left your device."
}

// V11-01: a "What this means for you" section, triggered by *owning the
// analyzed ticker* (not by a cloud-narrative cue, the way PersonalizedContext
// is). It references the user's real position in the analyzed stock, resolved
// on-device from the PrivateLedger so the specifics never transit the network.
//
// V11-02 extends it with concentration awareness: how big the position is as a
// share of the whole portfolio, and an honest weighing of the analysis's signal
// by that concentration ("you are 32% in AAPL — this overbought signal matters
// more given that concentration"). All of this is computed on-device from the
// holdings; only a *generalized* bucket (DifferentialPrivacy.positionBucket via
// FocusContext) ever reaches the cloud — the exact percentage never does.
struct PositionInsight: Equatable, Sendable {
    static let title = "What this means for you"

    // One or more lines referencing the held position (deterministic floor; an
    // optional on-device model may phrase the leading holding line more fluently).
    let lines: [String]
    // The analyzed ticker the user holds.
    let ticker: String
    // Exact "<count> shares of <TICKER>" phrases, for paraphrase validation.
    let factPhrases: [String]
    // Provenance — resolved on-device, never transmitted.
    let note: String
    // V11-02: the position's share of the whole portfolio by value, computed
    // on-device. nil when portfolio value can't be derived (e.g. no cost basis),
    // in which case no percentage is asserted ("when relevant"). The exact value
    // stays on-device; only a generalized bucket may reach the cloud.
    var portfolioPercent: Double? = nil
    // V11-02: the concentration bucket for the position ("concentrated", "large",
    // "moderate", "small", "tiny"), or nil when the percentage is unknown.
    var concentration: String? = nil
}

struct EnrichedResponse: Equatable, Sendable {
    // The original cloud analysis, byte-for-byte unchanged.
    let response: AnalysisResponse
    // nil when the cloud text referenced nothing we could map to a holding.
    let personalizedContext: PersonalizedContext?
    // V11-01: present when the user holds the analyzed ticker; nil otherwise.
    var positionInsight: PositionInsight? = nil

    // True when *any* on-device section was produced — the cue-based mapping or
    // the owned-ticker insight (V11-01).
    var didEnrich: Bool { personalizedContext != nil || positionInsight != nil }
}

struct Recontextualizer: Sendable {
    let gemma: GemmaService?

    init(gemma: GemmaService? = nil) {
        self.gemma = gemma
    }

    /// Map generalized portfolio references in `response` back to the specific
    /// holdings in `ledger`. Returns the original response plus an optional
    /// personalized-context section; never mutates the cloud analysis text.
    func enrich(response: AnalysisResponse, ledger: PrivateLedger?) async -> EnrichedResponse {
        await enrich(response: response, holdings: ledger?.holdings ?? [])
    }

    /// V11-01/P2: enrich against holdings aggregated across *all* imported
    /// ledgers, so a position held in an older account (or split across
    /// accounts) is still seen and counted.
    func enrich(response: AnalysisResponse, holdings: [LedgerHolding]) async -> EnrichedResponse {
        // V11-01: "What this means for you" — keyed on owning the analyzed
        // ticker, independent of the cloud cue that drives PersonalizedContext.
        let position = await enrichedPosition(response: response, holdings: holdings)

        guard let context = Self.personalizedContext(for: response, holdings: holdings) else {
            return EnrichedResponse(
                response: response, personalizedContext: nil, positionInsight: position
            )
        }

        // Optional: let a loaded on-device model phrase the mapping more
        // fluently. Accepted only if it preserves every fact the deterministic
        // lines asserted *and* introduces no advice — a guardrail, not a prompt.
        // A paraphrase that drops a holding, inflates a count, or slips in
        // buy/sell language is rejected and the deterministic lines stand.
        // Still zero network.
        if let gemma, await gemma.usesRealModel, await gemma.isReady,
           let prose = await modelSmooth(lines: context.lines, gemma: gemma),
           Self.preservesFacts(context, in: prose),
           !Self.containsAdvice(prose) {
            return EnrichedResponse(
                response: response,
                personalizedContext: PersonalizedContext(
                    lines: [prose],
                    tickers: context.tickers,
                    factPhrases: context.factPhrases,
                    note: PersonalizedContext.onDeviceNote
                ),
                positionInsight: position
            )
        }

        return EnrichedResponse(
            response: response, personalizedContext: context, positionInsight: position
        )
    }

    // MARK: - V11-01: position insight (owns the analyzed ticker)

    /// The "What this means for you" section, with an optional on-device Gemma
    /// smoothing pass over the *leading holding line only* (accepted only if it
    /// preserves the share-count + ticker fact *and* adds no advice). The V11-02
    /// concentration lines that follow are kept verbatim — they're deterministic
    /// framing that must stay honest and advice-free, so we never paraphrase
    /// them. Deterministic floor; zero network.
    func enrichedPosition(
        response: AnalysisResponse, holdings: [LedgerHolding]
    ) async -> PositionInsight? {
        guard let base = Self.positionInsight(for: response, holdings: holdings) else { return nil }
        guard let gemma, await gemma.usesRealModel, await gemma.isReady,
              let holdingLine = base.lines.first,
              let prose = await modelSmooth(lines: [holdingLine], gemma: gemma),
              Self.factsPreserved(base.factPhrases, in: prose),
              !Self.containsAdvice(prose) else {
            return base
        }
        var smoothed = base.lines
        smoothed[0] = prose
        return PositionInsight(
            lines: smoothed,
            ticker: base.ticker,
            factPhrases: base.factPhrases,
            note: base.note,
            portfolioPercent: base.portfolioPercent,
            concentration: base.concentration
        )
    }

    static func positionInsight(
        for response: AnalysisResponse, ledger: PrivateLedger?
    ) -> PositionInsight? {
        positionInsight(for: response, holdings: ledger?.holdings ?? [])
    }

    /// Build the position insight when the user holds the analyzed ticker, else
    /// nil (so the section is omitted gracefully). Pure and synchronous — the
    /// verifiable floor. Lots of the same ticker — across every passed-in
    /// holding — are aggregated into one figure (P2).
    ///
    /// V11-02: when the portfolio's value is derivable, append the position's
    /// share of the whole book and weigh the analysis's signal by that
    /// concentration — honest framing, never advice. The percentage is computed
    /// on-device and stays here; only a generalized bucket reaches the cloud.
    static func positionInsight(
        for response: AnalysisResponse, holdings: [LedgerHolding]
    ) -> PositionInsight? {
        let ticker = response.ticker.uppercased()
        guard !ticker.isEmpty else { return nil }
        let held = holdings.filter { $0.quantity > 0 }
        let lots = held.filter { $0.ticker.uppercased() == ticker }
        guard !lots.isEmpty else { return nil }

        let shares = lots.reduce(0.0) { $0 + $1.quantity }
        let phrase = "\(formatShares(shares)) shares of \(ticker)"
        // Leading holding line keeps the V11-01 form — it's the line the optional
        // Gemma pass may smooth, and the share-count fact it asserts is preserved.
        var lines = ["You own \(phrase), so this analysis is about a position you hold."]

        // V11-02: position size as a percentage of the whole portfolio by value.
        // Only derivable when we have cost basis for *every* held lot — a holding
        // with missing/zero basis contributes 0 to the denominator, which would
        // silently overstate the analyzed position's true share. When any basis
        // is missing we omit the percentage rather than assert a misleading one.
        let basisComplete = held.allSatisfy { $0.costBasis > 0 }
        let totalValue = held.reduce(0.0) { $0 + value(of: $1) }
        let positionValue = lots.reduce(0.0) { $0 + value(of: $1) }
        var percent: Double?
        var concentration: String?

        if basisComplete, totalValue > 0, positionValue > 0 {
            let pct = positionValue / totalValue * 100
            percent = pct
            let bucket = DifferentialPrivacy.positionBucket(forPercent: pct)
            concentration = bucket
            lines.append(
                "That's about \(formatPercent(pct)) of your portfolio — \(positionDescriptor(for: bucket))."
            )
            // Weigh the analysis's strongest signal by concentration, when the
            // size meaningfully changes how much that signal matters.
            if let signal = salientSignal(in: response.analysis.technical),
               let weighting = concentrationWeighting(ticker: ticker, signal: signal, bucket: bucket) {
                lines.append(weighting)
            }
        }

        return PositionInsight(
            lines: lines,
            ticker: ticker,
            factPhrases: [phrase],
            note: PersonalizedContext.onDeviceNote,
            portfolioPercent: percent,
            concentration: concentration
        )
    }

    // MARK: - V11-02: concentration + signal weighing

    /// The strongest plain-language signal the analyst's technical indicators
    /// imply, or nil when they're all neutral / absent. Deterministic — no LLM
    /// math (per CLAUDE.md) — and mirrors the thresholds IndicatorFormatter uses
    /// for its UI tags so the framing never contradicts the indicator table.
    /// RSI leads (the design's canonical example), then Bollinger, then MACD.
    static func salientSignal(in technical: [String: JSONValue]) -> String? {
        if let rsi = number(technical["rsi"]) {
            if rsi >= 70 { return "overbought" }
            if rsi <= 30 { return "oversold" }
        }
        if case .object(let bands)? = technical["bollinger"],
           let close = number(technical["latest_close"]),
           let upper = number(bands["upper"]),
           let lower = number(bands["lower"]) {
            if close > upper { return "overextended" }
            if close < lower { return "depressed" }
        }
        if case .object(let macd)? = technical["macd"], let histogram = number(macd["histogram"]) {
            if histogram > 0 { return "bullish" }
            if histogram < 0 { return "bearish" }
        }
        return nil
    }

    /// Honest framing that scales the signal by how concentrated the position is.
    /// A concentrated/large stake amplifies the signal's relevance; a tiny/small
    /// one dampens it; a moderate stake gets no amplification claim (nil) so we
    /// don't overstate. Never advice — only a statement of relative relevance.
    static func concentrationWeighting(ticker: String, signal: String, bucket: String) -> String? {
        switch bucket {
        case "concentrated", "large":
            let share = bucket == "concentrated" ? "such a large share" : "a sizable share"
            return "Because \(ticker) is \(share) of your portfolio, this \(signal) signal "
                + "carries more weight for you than it would in a smaller position."
        case "small", "tiny":
            let share = bucket == "tiny" ? "only a tiny share" : "only a small share"
            return "Because \(ticker) is \(share) of your portfolio, this \(signal) signal "
                + "is a smaller factor for you than it would be in a concentrated position."
        default:
            // "moderate" — no honest amplification either way; the percentage stands.
            return nil
        }
    }

    // Human label for a position-size bucket, used in the percentage line.
    private static func positionDescriptor(for bucket: String) -> String {
        switch bucket {
        case "concentrated": return "a concentrated position"
        case "large": return "a large position"
        case "moderate": return "a moderate position"
        case "small": return "a small position"
        case "tiny": return "a tiny position"
        default: return "a position"
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    // MARK: - Deterministic core

    static func personalizedContext(
        for response: AnalysisResponse,
        ledger: PrivateLedger?
    ) -> PersonalizedContext? {
        personalizedContext(for: response, holdings: ledger?.holdings ?? [])
    }

    /// Build the personalized-context section, or nil when nothing maps. Pure
    /// and synchronous so it's directly testable and is the verifiable floor.
    /// Operates on holdings aggregated across all imported ledgers (P2).
    static func personalizedContext(
        for response: AnalysisResponse,
        holdings allHoldings: [LedgerHolding]
    ) -> PersonalizedContext? {
        let holdings = allHoldings.filter { $0.quantity > 0 }
        guard !holdings.isEmpty else { return nil }

        // We map references only against text describing the *portfolio*. A
        // bare sector mention about a company ("NVDA's competitive position")
        // must not trigger enrichment — require a personal-portfolio cue.
        let text = (response.analysis.narrative + " " + response.riskReview.modifiedResponse).lowercased()
        guard containsPortfolioCue(text) else { return nil }

        // Group holdings into the same coarse categories the privacy module
        // generalizes to, so a "tech" mention resolves to every tech holding.
        var byCategory: [String: [LedgerHolding]] = [:]
        for holding in holdings {
            let category = DifferentialPrivacy.category(for: SectorClassifier.sector(for: holding.ticker))
            byCategory[category, default: []].append(holding)
        }

        // Categories the cloud text actually named *and* the user holds,
        // ordered largest-held-value first for a stable, useful read.
        let matched = byCategory.keys
            .filter { category in keywords(for: category).contains(where: text.contains) }
            .sorted { value(of: byCategory[$0] ?? []) > value(of: byCategory[$1] ?? []) }

        var lines: [String] = []
        var tickers: [String] = []
        var factPhrases: [String] = []

        if !matched.isEmpty {
            for category in matched {
                let sorted = (byCategory[category] ?? []).sorted { value(of: $0) > value(of: $1) }
                lines.append("Your \(displayName(for: category)) exposure: \(holdingList(sorted)).")
                tickers.append(contentsOf: sorted.map { $0.ticker.uppercased() })
                factPhrases.append(contentsOf: sorted.map(holdingPhrase))
            }
        } else {
            // A portfolio cue with no nameable sector ("your concentrated
            // position", "well diversified") — surface the largest holdings so
            // the generality still resolves to concrete names.
            let top = Array(holdings.sorted { value(of: $0) > value(of: $1) }.prefix(3))
            lines.append("Based on your holdings: \(holdingList(top)).")
            tickers.append(contentsOf: top.map { $0.ticker.uppercased() })
            factPhrases.append(contentsOf: top.map(holdingPhrase))
        }

        guard !lines.isEmpty else { return nil }
        return PersonalizedContext(
            lines: lines,
            tickers: tickers,
            factPhrases: factPhrases,
            note: PersonalizedContext.onDeviceNote
        )
    }

    // MARK: - Cue + sector vocabulary

    // A cue must be *explicitly* about the user's book, not a bare word that
    // also shows up in company/market commentary. "Apple's capital allocation
    // in the technology sector" or "analysts are overweight Apple" must NOT
    // enrich. We require either second-person possessive phrasing ("your …
    // portfolio/allocation/exposure", allowing a sector modifier as in "your
    // financials allocation") or an explicit portfolio phrase. This mirrors the
    // design's own canonical generalization — "the portfolio's concentrated
    // tech position" — and IntentRouter.personalPortfolioPattern's shape.
    private static let personalCuePattern = makeRegex(
        #"\byour\s+(?:\w+\s+){0,2}(portfolios?|allocations?|holdings?|positions?|exposure|stake|book|concentration|diversification|investments?|weighting|equit\w*|tilt)\b"#
    )
    // Portfolio references that don't use "your" but are still unambiguously
    // about the held book rather than a company.
    private static let portfolioPhrases = [
        "the portfolio", "portfolio allocation", "portfolio concentration",
        "tech-heavy portfolio", "-heavy portfolio",
    ]

    static func containsPortfolioCue(_ loweredText: String) -> Bool {
        if portfolioPhrases.contains(where: loweredText.contains) { return true }
        let ns = loweredText as NSString
        return personalCuePattern.firstMatch(
            in: loweredText,
            range: NSRange(location: 0, length: ns.length)
        ) != nil
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        // Compile-time constant pattern; a failure is a programmer error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // V11-01 (P1): a hard guard on the optional Gemma smoothing. This module
    // restates portfolio *facts* — it must never emit advice. A model paraphrase
    // that slips in buy/sell/hold directives is rejected (the deterministic line
    // stands), regardless of what the prompt asked for. Note that the legitimate
    // phrasing "a position you hold" / "you own" is NOT advice — only directive
    // verbs paired with an action trigger are.
    private static let advicePatterns: [NSRegularExpression] = [
        makeRegex(#"\bshould\s+(?:buy|sell|short|hold|exit|trim|reduce|add|dump|avoid|get\s+out)\b"#),
        makeRegex(#"\b(?:recommend(?:s|ed|ation)?|advis(?:e|es|ed)|advice)\b"#),
        makeRegex(#"\b(?:buy|sell)\s+(?:now|immediately|this|the\s+stock)\b"#),
        makeRegex(#"\bconsider\s+(?:buying|selling|shorting|exiting|trimming|adding)\b"#),
        makeRegex(#"\b(?:it'?s\s+)?time\s+to\s+(?:buy|sell|short|exit)\b"#),
        makeRegex(#"\b(?:take\s+profits?|cut\s+(?:your\s+)?losses)\b"#),
        makeRegex(#"\b(?:reduce|trim|increase|lighten|boost)\s+(?:your\s+)?(?:exposure|position|holdings?|stake)\b"#),
        // Recommendation-*shaped* phrasing that uses no directive verb but still
        // reads as advice: analyst-style ratings ("a strong buy", "rated a sell",
        // "buy rating", "outperform") and "hold this position" imperatives. These
        // would otherwise preserve the share-count fact and slip past the guard.
        // Note "a position you hold" / "you own" are NOT matched — the hold rule
        // requires hold to *precede* this/the/your/onto + the noun.
        makeRegex(#"\b(?:a|an|its)\s+strong\s+(?:buy|sell)\b"#),
        makeRegex(#"\bstrong\s+(?:buy|sell)\b"#),
        makeRegex(#"\b(?:a|an)\s+(?:buy|sell)\b"#),
        makeRegex(#"\b(?:buy|sell|hold)\s+rating\b"#),
        makeRegex(#"\brated\s+(?:a\s+)?(?:strong\s+)?(?:buy|sell|hold|outperform|underperform|overweight|underweight)\b"#),
        makeRegex(#"\bhold\s+(?:on\s+to\s+|onto\s+)?(?:this\s+|the\s+|your\s+)?(?:position|stock|shares?|holding)\b"#),
        makeRegex(#"\b(?:outperform|underperform)\b"#),
    ]

    static func containsAdvice(_ text: String) -> Bool {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return advicePatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // Detection keywords per coarse category (matched against lowercased text).
    private static func keywords(for category: String) -> [String] {
        switch category {
        case "tech": return ["tech", "technology"]
        case "communication": return ["communication"]
        case "consumer_discretionary": return ["consumer discretionary", "discretionary"]
        case "consumer_staples": return ["consumer staples", "staples"]
        case "financials": return ["financial", "bank"]
        case "healthcare": return ["health"]
        case "energy": return ["energy"]
        case "utilities": return ["utilit"]
        case "real_estate": return ["real estate", "reit"]
        case "materials": return ["materials"]
        case "industrials": return ["industrial"]
        case "fixed_income": return ["fixed income", "bond"]
        case "cash": return ["cash"]
        default: return []
        }
    }

    private static func displayName(for category: String) -> String {
        switch category {
        case "tech": return "technology"
        case "communication": return "communication services"
        case "consumer_discretionary": return "consumer discretionary"
        case "consumer_staples": return "consumer staples"
        case "financials": return "financials"
        case "healthcare": return "healthcare"
        case "energy": return "energy"
        case "utilities": return "utilities"
        case "real_estate": return "real estate"
        case "materials": return "materials"
        case "industrials": return "industrials"
        case "fixed_income": return "fixed income"
        case "cash": return "cash"
        default: return "other"
        }
    }

    // MARK: - Formatting

    private static func value(of holding: LedgerHolding) -> Double {
        holding.quantity * holding.costBasis
    }

    private static func value(of holdings: [LedgerHolding]) -> Double {
        holdings.reduce(0) { $0 + value(of: $1) }
    }

    private static func holdingPhrase(_ holding: LedgerHolding) -> String {
        "\(formatShares(holding.quantity)) shares of \(holding.ticker.uppercased())"
    }

    private static func holdingList(_ holdings: [LedgerHolding]) -> String {
        let phrases = holdings.map(holdingPhrase)
        switch phrases.count {
        case 0: return ""
        case 1: return phrases[0]
        case 2: return "\(phrases[0]) and \(phrases[1])"
        default:
            let head = phrases.dropLast().joined(separator: ", ")
            return "\(head), and \(phrases.last!)"
        }
    }

    private static func formatShares(_ quantity: Double) -> String {
        if quantity == quantity.rounded() {
            return String(Int(quantity))
        }
        // Trim trailing zeros for fractional share counts (e.g. 12.50 → 12.5).
        return String(format: "%g", quantity)
    }

    // Position size as a readable percentage. Rounds to a whole percent — the
    // figure is contextual framing, not a number to act on — and floors sub-1%
    // stakes to "less than 1%" rather than printing a misleading "0%".
    static func formatPercent(_ percent: Double) -> String {
        percent < 1 ? "less than 1%" : "\(Int(percent.rounded()))%"
    }

    // MARK: - Gemma smoothing (real model only)

    private func modelSmooth(lines: [String], gemma: GemmaService) async -> String? {
        let prompt = """
        Rewrite the portfolio facts below as one short, fluent sentence. Keep \
        every ticker symbol and share count exactly. Do not add advice. Reply \
        with only the sentence.

        Facts: \(lines.joined(separator: " "))
        """
        var output = ""
        let stream = await gemma.generate(prompt: prompt, maxTokens: 96)
        for await token in stream {
            output += token
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // A smoothed paraphrase is trustworthy only if every holding survives as a
    // *paired unit* — the exact "<count> shares of <TICKER>" phrase. Validating
    // tokens independently is unsafe: a substring check would accept "1500
    // shares of AAPL" for a required count of 500, and would accept a swapped
    // "200 shares of AAPL / 500 shares of MSFT" because the loose tokens all
    // appear. Each phrase is matched with word boundaries so an inflated count
    // (1500 vs 500) or a ticker prefix (AAPLE vs AAPL) cannot satisfy it. A
    // faithful rewrite that reorders within a phrase is conservatively rejected
    // and the deterministic lines stand.
    static func preservesFacts(_ context: PersonalizedContext, in prose: String) -> Bool {
        factsPreserved(context.factPhrases, in: prose)
    }

    /// True iff every "<count> shares of <TICKER>" phrase survives in ``prose``
    /// as an intact, word-bounded unit. Shared by the P5-08 mapping and the
    /// V11-01 position insight so both reject inflated counts / prefix collisions.
    static func factsPreserved(_ factPhrases: [String], in prose: String) -> Bool {
        let ns = prose as NSString
        let range = NSRange(location: 0, length: ns.length)
        return factPhrases.allSatisfy { phrase in
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: prose, range: range) != nil
        }
    }
}
