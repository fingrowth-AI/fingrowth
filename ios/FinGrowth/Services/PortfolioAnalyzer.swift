import Foundation

// V11-03: Portfolio-level analysis (the differentiator).
//
// Every other analysis is single-ticker. This produces a "how is my whole
// portfolio" view: diversification, sector concentration, and overall risk.
//
// It runs entirely on-device from the *generalized* portfolio context — the
// same lossy GeneralizedProfile the privacy module would send to the cloud
// (sector categories + buckets), never the raw ledger and never identity. That
// satisfies the V11-03 acceptance criterion that the analysis use query-scoped
// generalized context, never raw identity: the analyzer literally cannot see a
// holding, an account number, or a holder name — only category weights and
// generalized buckets.
//
// The findings are interpreted in plain language, consistent with Phase 10:
// a short readable conclusion, honest framing, and never directive advice.

struct PortfolioFinding: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable, CaseIterable {
        case diversification, concentration, risk
    }
    let kind: Kind
    // Short label for the row's chip ("Well diversified", "Top sector").
    let tag: String
    // Plain-language sentence explaining the finding.
    let detail: String
}

struct PortfolioAnalysis: Equatable, Sendable {
    static let title = "Portfolio overview"

    // Phase 10: a short plain-language conclusion shown above the findings.
    let lead: String
    // At minimum diversification + sector concentration; risk when the privacy
    // level exposes a risk score.
    let findings: [PortfolioFinding]
    let disclaimer: String
    // Provenance — computed on-device from generalized context, nothing left.
    let note: String
}

enum PortfolioAnalyzer {
    static let onDeviceNote = "Built on-device from your generalized portfolio profile — only sector "
        + "categories and buckets, never your holdings or identity."

    static let standardDisclaimer = "This is a research tool, not financial advice. This overview "
        + "summarizes your imported holdings — always verify before acting."

    // MARK: - Query detection

    /// Whether `query` asks about the *whole* book (diversification, allocation,
    /// concentration, overall risk) rather than a single ticker. Conservative:
    /// it requires an explicit whole-portfolio cue so a single-stock question
    /// ("how is my AAPL doing") never routes here.
    static func isPortfolioLevelQuery(_ query: String) -> Bool {
        let q = query.lowercased()
        let wholeBookCues = [
            "my portfolio", "whole portfolio", "entire portfolio", "overall portfolio",
            "my holdings", "my allocation", "asset allocation", "my investments",
            "my sectors", "my diversification", "my book", "my mix", "my exposure",
        ]
        if wholeBookCues.contains(where: q.contains) { return true }
        // "how diversified am i", "is my portfolio concentrated", "my sector mix".
        let topical = ["diversif", "concentrat", "allocation", "sector mix", "asset mix"]
        let personal = q.contains("portfolio") || q.contains("am i") || q.contains("my ")
        return personal && topical.contains(where: q.contains)
    }

    // MARK: - Analysis

    /// Build the portfolio-level analysis from the generalized context, or nil
    /// when there are no sector weights to summarize (e.g. no portfolio imported).
    /// Pure and synchronous — the verifiable floor.
    static func analyze(
        _ profile: GeneralizedProfile,
        disclaimer: String = standardDisclaimer
    ) -> PortfolioAnalysis? {
        let weights = profile.sectorWeights.filter { $0.value > 0 }
        let total = weights.values.reduce(0, +)
        guard !weights.isEmpty, total > 0 else { return nil }

        // Diversification (AC: a portfolio-level query returns diversification).
        let divLabel = DifferentialPrivacy.diversificationLevel(profile.sectorWeights) ?? "moderate"
        var findings = [diversificationFinding(label: divLabel, sectorCount: weights.count)]

        // Sector concentration (AC: ...and sector-concentration findings).
        let sorted = weights.sorted { $0.value > $1.value }
        let topCategory = sorted[0].key
        let topPercent = sorted[0].value / total * 100
        findings.append(concentrationFinding(category: topCategory, percent: topPercent))

        // Overall risk — only when the privacy level exposes a risk score
        // (detailed). Omitted gracefully otherwise rather than fabricated.
        let orientation = profile.riskScore.map(riskOrientation)
        if let orientation {
            findings.append(riskFinding(orientation: orientation))
        }

        return PortfolioAnalysis(
            lead: makeLead(
                divLabel: divLabel,
                topCategory: topCategory,
                topPercent: topPercent,
                orientation: orientation
            ),
            findings: findings,
            disclaimer: disclaimer,
            note: onDeviceNote
        )
    }

    // MARK: - Findings

    private static func diversificationFinding(label: String, sectorCount: Int) -> PortfolioFinding {
        let sectors = sectorCount == 1 ? "sector" : "sectors"
        switch label {
        case "high":
            return PortfolioFinding(
                kind: .diversification,
                tag: "Well diversified",
                detail: "Your holdings spread across \(sectorCount) \(sectors), so no single area dominates."
            )
        case "low":
            return PortfolioFinding(
                kind: .diversification,
                tag: "Concentrated",
                detail: "Your holdings sit in just \(sectorCount) \(sectors), so the portfolio leans "
                    + "heavily on a few areas."
            )
        default:
            return PortfolioFinding(
                kind: .diversification,
                tag: "Moderately diversified",
                detail: "Your holdings span \(sectorCount) \(sectors), giving moderate diversification."
            )
        }
    }

    private static func concentrationFinding(category: String, percent: Double) -> PortfolioFinding {
        let name = displayName(for: category)
        return PortfolioFinding(
            kind: .concentration,
            tag: "Top sector",
            detail: "\(name.capitalizedFirst) is your largest area at about "
                + "\(Recontextualizer.formatPercent(percent)) of the portfolio."
        )
    }

    private static func riskFinding(orientation: String) -> PortfolioFinding {
        let detail: String
        switch orientation {
        case "aggressive":
            detail = "The mix reads as aggressive — weighted toward higher-volatility holdings."
        case "conservative":
            detail = "The mix reads as conservative — weighted toward steadier holdings."
        default:
            detail = "The mix reads as balanced between steadier and higher-volatility holdings."
        }
        return PortfolioFinding(kind: .risk, tag: orientation.capitalizedFirst, detail: detail)
    }

    // Phase 10: a short, plain-language conclusion that leads the result.
    private static func makeLead(
        divLabel: String,
        topCategory: String,
        topPercent: Double,
        orientation: String?
    ) -> String {
        let divPhrase: String
        switch divLabel {
        case "high": divPhrase = "well diversified"
        case "low": divPhrase = "concentrated"
        default: divPhrase = "moderately diversified"
        }
        var lead = "Your portfolio looks \(divPhrase), with \(displayName(for: topCategory)) as its "
            + "largest area at about \(Recontextualizer.formatPercent(topPercent))."
        if let orientation {
            lead += " Overall, the mix reads as \(orientation)."
        }
        return lead
    }

    // MARK: - Mappings

    // Risk score → orientation. Mirrors the bucketing the wire profile uses so
    // the on-device read agrees with what the cloud would have been told.
    static func riskOrientation(_ score: Double) -> String {
        switch score {
        case ..<0.34: return "conservative"
        case ..<0.67: return "balanced"
        default: return "aggressive"
        }
    }

    // Coarse category → display name. Mirrors DifferentialPrivacy's category
    // vocabulary so a "tech" weight reads as "technology".
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
        default: return "other holdings"
        }
    }
}

private extension String {
    // Uppercase only the first character, leaving the rest untouched ("fixed
    // income" → "Fixed income"). `capitalized` would wrongly title-case every
    // word ("Fixed Income").
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
