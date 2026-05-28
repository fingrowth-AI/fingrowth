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
    // The specific tickers surfaced in `lines`. Used to validate that an
    // optional model paraphrase didn't silently drop a holding.
    let tickers: [String]
    // Provenance note — these specifics were resolved on-device and never left.
    let note: String

    static let onDeviceNote = "Matched on-device from your private ledger — these specifics never left your device."
}

struct EnrichedResponse: Equatable, Sendable {
    // The original cloud analysis, byte-for-byte unchanged.
    let response: AnalysisResponse
    // nil when the cloud text referenced nothing we could map to a holding.
    let personalizedContext: PersonalizedContext?

    var didEnrich: Bool { personalizedContext != nil }
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
        guard let context = Self.personalizedContext(for: response, ledger: ledger) else {
            return EnrichedResponse(response: response, personalizedContext: nil)
        }

        // Optional: let a loaded on-device model phrase the mapping more
        // fluently. Accepted only if it preserves every fact the deterministic
        // lines asserted — both the tickers *and* their share counts. A
        // paraphrase that drops a holding or rounds "500 shares" to "some
        // shares" would quietly corrupt trusted context, so the deterministic
        // lines remain the floor. Still zero network.
        if let gemma, await gemma.usesRealModel, await gemma.isReady,
           let prose = await modelSmooth(lines: context.lines, gemma: gemma),
           Self.preservesFacts(context, in: prose) {
            return EnrichedResponse(
                response: response,
                personalizedContext: PersonalizedContext(
                    lines: [prose],
                    tickers: context.tickers,
                    note: PersonalizedContext.onDeviceNote
                )
            )
        }

        return EnrichedResponse(response: response, personalizedContext: context)
    }

    // MARK: - Deterministic core

    /// Build the personalized-context section, or nil when nothing maps. Pure
    /// and synchronous so it's directly testable and is the verifiable floor.
    static func personalizedContext(
        for response: AnalysisResponse,
        ledger: PrivateLedger?
    ) -> PersonalizedContext? {
        guard let ledger else { return nil }
        let holdings = ledger.holdings.filter { $0.quantity > 0 }
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

        if !matched.isEmpty {
            for category in matched {
                let sorted = (byCategory[category] ?? []).sorted { value(of: $0) > value(of: $1) }
                lines.append("Your \(displayName(for: category)) exposure: \(holdingList(sorted)).")
                tickers.append(contentsOf: sorted.map { $0.ticker.uppercased() })
            }
        } else {
            // A portfolio cue with no nameable sector ("your concentrated
            // position", "well diversified") — surface the largest holdings so
            // the generality still resolves to concrete names.
            let top = Array(holdings.sorted { value(of: $0) > value(of: $1) }.prefix(3))
            lines.append("Based on your holdings: \(holdingList(top)).")
            tickers.append(contentsOf: top.map { $0.ticker.uppercased() })
        }

        guard !lines.isEmpty else { return nil }
        return PersonalizedContext(lines: lines, tickers: tickers, note: PersonalizedContext.onDeviceNote)
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

    // A smoothed paraphrase is trustworthy only if every fact the deterministic
    // lines asserted survives: each ticker symbol and each share count. This is
    // what lets us label the result trusted "personalized context".
    static func preservesFacts(_ context: PersonalizedContext, in prose: String) -> Bool {
        let required = context.tickers + shareCounts(in: context.lines)
        return mentionsAll(required, in: prose)
    }

    static func mentionsAll(_ tokens: [String], in text: String) -> Bool {
        let upper = text.uppercased()
        return tokens.allSatisfy { upper.contains($0.uppercased()) }
    }

    private static let shareCountRegex = makeRegex(#"(\d[\d,]*\.?\d*)\s+shares\b"#)

    // The share-count tokens ("500", "12.5") asserted by the deterministic
    // lines, pulled back out so a paraphrase can be checked against them.
    static func shareCounts(in lines: [String]) -> [String] {
        var counts: [String] = []
        for line in lines {
            let ns = line as NSString
            for match in shareCountRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                counts.append(ns.substring(with: match.range(at: 1)))
            }
        }
        return counts
    }
}
