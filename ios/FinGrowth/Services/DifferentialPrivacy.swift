import Foundation

// Differential privacy for portfolio context (P5-05).
//
// Turns a ShareableProfile into a lossy, bucketed GeneralizedProfile that's
// safe to send to the cloud: instead of "500 shares AAPL at $142", the cloud
// sees "tech-heavy, concentrated, low diversification". The generalization is
// lossy by design — enough context for useful analysis, while making
// re-identification of the specific portfolio statistically impractical.
//
// Deterministic and PII-free: identical holdings always produce an identical
// GeneralizedProfile regardless of account number / ledger identity.

enum PortfolioPrivacyLevel: String, CaseIterable, Codable, Sendable, Identifiable {
    case minimal   // sector weights only
    case moderate  // + position-size bucket + diversification
    case detailed  // + risk metrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .moderate: return "Moderate"
        case .detailed: return "Detailed"
        }
    }

    var summary: String {
        switch self {
        case .minimal: return "Share only generalized sector weights."
        case .moderate: return "Add position-size bucket and diversification."
        case .detailed: return "Add risk metrics and value band."
        }
    }
}

// Plain struct with no reference to PrivateLedger / ShareableProfile identity.
struct GeneralizedProfile: Codable, Equatable, Sendable {
    let privacyLevel: PortfolioPrivacyLevel
    // Coarse category → percent (e.g. {"tech": 75, "fixed_income": 25}). Never
    // contains ticker symbols.
    let sectorWeights: [String: Double]
    // moderate+: bucket of the largest category and overall diversification.
    let largestPosition: String?
    let diversification: String?
    // detailed+: generalized risk metrics.
    let riskScore: Double?
    let valueBucket: String?
    // V9-03: query-scoped focus holdings. Populated only for a focused query
    // (one or more held tickers named in the question); nil for a portfolio-level
    // question, where `sectorWeights` carries the context instead.
    var focus: [FocusContext]? = nil
}

enum DifferentialPrivacy {
    static func generalize(
        profile: ShareableProfile,
        privacyLevel: PortfolioPrivacyLevel
    ) -> GeneralizedProfile {
        let categories = aggregateByCategory(decodeWeights(profile.sectorWeightsJSON))

        switch privacyLevel {
        case .minimal:
            return GeneralizedProfile(
                privacyLevel: .minimal,
                sectorWeights: categories,
                largestPosition: nil,
                diversification: nil,
                riskScore: nil,
                valueBucket: nil
            )
        case .moderate:
            return GeneralizedProfile(
                privacyLevel: .moderate,
                sectorWeights: categories,
                largestPosition: largestPositionBucket(profile),
                diversification: diversificationLevel(categories),
                riskScore: nil,
                valueBucket: nil
            )
        case .detailed:
            return GeneralizedProfile(
                privacyLevel: .detailed,
                sectorWeights: categories,
                largestPosition: largestPositionBucket(profile),
                diversification: diversificationLevel(categories),
                riskScore: profile.riskScore,
                valueBucket: profile.totalValueBucket
            )
        }
    }

    // MARK: - Query-scoped context (V9-03)

    // Scope the outbound portfolio context to the question instead of always
    // shipping one fixed profile:
    //
    //   * Focused query (names one or more *held* tickers): send just those
    //     holdings' tier-2 specifics (ticker, generalized sector, position-size
    //     bucket) plus minimal context (overall diversification). The exact
    //     ticker + share count already ride in the rewritten query text (V9-02),
    //     so the whole-portfolio sector breakdown is withheld — only the
    //     query-relevant subset of the ledger leaves.
    //   * Portfolio-level query (no held ticker named): the existing
    //     sector-weights + concentration profile.
    //
    // Identity is never included in either branch — the result is built from
    // sectors / sizes / public tickers, never from the ledger's account number
    // or holder. Deterministic and PII-free like `generalize`.
    static func scopedContext(
        query: String,
        ledger: PrivateLedger?,
        profile: ShareableProfile,
        privacyLevel: PortfolioPrivacyLevel
    ) -> GeneralizedProfile {
        scopedContext(
            query: query,
            holdings: ledger?.holdings ?? [],
            profile: profile,
            privacyLevel: privacyLevel
        )
    }

    // V11-02 (P2): scope against an explicit holdings set so the caller can pass
    // holdings aggregated across *every* imported ledger. The concentration the
    // cloud sees (the focus position-size bucket) is then computed over the same
    // book as the on-device "What this means for you" card, instead of only the
    // newest account — keeping the two from disagreeing. Still emits only tier-2
    // generalities (ticker + sector + size bucket); no identity, no exact value.
    static func scopedContext(
        query: String,
        holdings allHoldings: [LedgerHolding],
        profile: ShareableProfile,
        privacyLevel: PortfolioPrivacyLevel
    ) -> GeneralizedProfile {
        let holdings = allHoldings.filter { $0.quantity > 0 }
        let focusTickers = focusedTickers(in: query, held: holdings)

        // No specific holding in question → portfolio-level context as before.
        guard !focusTickers.isEmpty else {
            return generalize(profile: profile, privacyLevel: privacyLevel)
        }

        let totalValue = holdings.reduce(0) { $0 + $1.quantity * $1.costBasis }
        // Aggregate lots by ticker first: a multi-lot holding is ONE focus entry
        // with the combined position size, never per-row structure. Sending two
        // TSLA rows would leak the lot layout and understate concentration
        // (V9-03 scoping guard).
        var valueByTicker: [String: Double] = [:]
        for holding in holdings where focusTickers.contains(holding.ticker.uppercased()) {
            valueByTicker[holding.ticker.uppercased(), default: 0] += holding.quantity * holding.costBasis
        }
        let focus = valueByTicker.keys.sorted().map { ticker -> FocusContext in
            let percent = totalValue > 0 ? (valueByTicker[ticker] ?? 0) / totalValue * 100 : 0
            return FocusContext(
                ticker: ticker,
                sector: category(for: SectorClassifier.sector(for: ticker)),
                positionSize: positionBucket(forPercent: percent)
            )
        }

        // Minimal context: overall diversification (moderate+ only). The whole
        // portfolio's sector weights, value band, and risk score are deliberately
        // omitted — they're not relevant to a single-holding question.
        let categories = aggregateByCategory(decodeWeights(profile.sectorWeightsJSON))
        let diversification = privacyLevel == .minimal ? nil : diversificationLevel(categories)

        return GeneralizedProfile(
            privacyLevel: privacyLevel,
            sectorWeights: [:],
            largestPosition: nil,
            diversification: diversification,
            riskScore: nil,
            valueBucket: nil,
            focus: focus
        )
    }

    // Held tickers named in the query, matched whole-word and case-insensitively
    // so "Value investing" never trips the ticker "V". Restricting to *held*
    // tickers means an unrelated symbol in the text can't pull in portfolio data.
    static func focusedTickers(in query: String, held: [LedgerHolding]) -> Set<String> {
        let upper = query.uppercased()
        var found: Set<String> = []
        for holding in held {
            let ticker = holding.ticker.uppercased()
            guard !ticker.isEmpty else { continue }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: ticker) + "\\b"
            if upper.range(of: pattern, options: .regularExpression) != nil {
                found.insert(ticker)
            }
        }
        return found
    }

    // MARK: - Position-size buckets (design §P5-05)

    // tiny (<1%), small (1-5%), moderate (5-15%), large (15-30%), concentrated (>30%)
    static func positionBucket(forPercent percent: Double) -> String {
        switch percent {
        case ..<1: return "tiny"
        case ..<5: return "small"
        case ..<15: return "moderate"
        case ..<30, 30: return "large"
        default: return "concentrated"
        }
    }

    // Buckets ordered smallest → largest so we can pick the biggest *position*.
    private static let bucketRank = ["tiny", "small", "moderate", "large", "concentrated"]

    // The largest individual position's bucket, read from the buckets computed
    // per holding at import — NOT the largest sector aggregate. Five 20% tech
    // holdings read "large", not "concentrated".
    private static func largestPositionBucket(_ profile: ShareableProfile) -> String? {
        let buckets = decodeBuckets(profile.positionSizeBucketsJSON)
        return buckets.max { (bucketRank.firstIndex(of: $0) ?? -1) < (bucketRank.firstIndex(of: $1) ?? -1) }
    }

    private static func decodeBuckets(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return array
    }

    // Herfindahl-based: a concentrated book is low-diversification.
    private static func diversificationLevel(_ categories: [String: Double]) -> String? {
        let total = categories.values.reduce(0, +)
        guard total > 0 else { return nil }
        let hhi = categories.values.map { ($0 / total) * ($0 / total) }.reduce(0, +)
        switch hhi {
        case let h where h > 0.5: return "low"
        case let h where h > 0.25: return "moderate"
        default: return "high"
        }
    }

    // MARK: - Sector → coarse category

    private static func aggregateByCategory(_ sectorWeights: [String: Double]) -> [String: Double] {
        var byCategory: [String: Double] = [:]
        for (sector, weight) in sectorWeights where weight > 0 {
            byCategory[category(for: sector), default: 0] += weight
        }
        // Round to 2 dp; deterministic and free of float noise.
        return byCategory.mapValues { ($0 * 100).rounded() / 100 }
    }

    // Maps both GICS sector names (as produced by SectorClassifier) and
    // already-coarse labels onto a small, stable category vocabulary.
    private static let categoryMap: [String: String] = [
        "information technology": "tech",
        "technology": "tech",
        "tech": "tech",
        "communication services": "communication",
        "communication": "communication",
        "consumer discretionary": "consumer_discretionary",
        "consumer staples": "consumer_staples",
        "financials": "financials",
        "financial": "financials",
        "health care": "healthcare",
        "healthcare": "healthcare",
        "energy": "energy",
        "utilities": "utilities",
        "real estate": "real_estate",
        "materials": "materials",
        "industrials": "industrials",
        "fixed income": "fixed_income",
        "fixed_income": "fixed_income",
        "bonds": "fixed_income",
        "bond": "fixed_income",
        "cash": "cash",
        "other": "other",
    ]

    static func category(for sector: String) -> String {
        categoryMap[sector.lowercased().trimmingCharacters(in: .whitespaces)] ?? "other"
    }

    private static func decodeWeights(_ json: String) -> [String: Double] {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return [:] }
        return dict.compactMapValues { value in
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let n = value as? NSNumber { return n.doubleValue }
            return nil
        }
    }
}
