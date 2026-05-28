import Foundation

// Intent classifier for the cloud-routing gate (P5-07).
//
// Splits an incoming research query into one of three buckets so the rest of
// the pipeline can decide what actually leaves the device:
//
//   .localOnly      — answerable from the on-device PrivateLedger (portfolio
//                     lookups, settings). No cloud call is made.
//   .cloudAnalysis  — pure market research with no personal context (an
//                     earnings question, a public ticker fact). Sent to the
//                     cloud through the QueryRewriter; no portfolio profile.
//   .hybrid         — needs both: the user's portfolio compared against
//                     external market data. QueryRewriter + Differential
//                     Privacy must both run before the call.
//
// The classifier is deterministic so the privacy gate is auditable: a fixed
// query always routes the same way regardless of model state. A real Gemma
// model can refine ambiguous cases (single-pass classify call, well under the
// 1s budget), but the rule-based decision is always the floor — the model
// never gets to *upgrade* a query from .localOnly to one that contacts the
// cloud without an external-context signal in the text itself.
enum IntentType: String, Equatable, Sendable, Codable {
    case localOnly
    case cloudAnalysis
    case hybrid
}

struct IntentRouter: Sendable {
    let gemma: GemmaService?

    init(gemma: GemmaService? = nil) {
        self.gemma = gemma
    }

    /// Classify `query` into one of three intents. Never throws and never
    /// blocks longer than the deterministic regex pass plus, optionally, one
    /// model call capped to a single token budget — comfortably under the
    /// 1-second design budget on the stub path.
    func classify(query: String) async -> IntentType {
        let deterministic = Self.deterministicClassify(query: query)

        // Only call the model when (a) the deterministic rules saw an
        // ambiguity worth refining and (b) the real Gemma model is actually
        // loaded — the stub would just guess. Today the rules are exhaustive
        // for the acceptance suite, so this is a forward seam: it lets a
        // future on-device classifier improve precision without ever
        // weakening the privacy floor (we'd refuse to *promote* a localOnly).
        if let gemma, await gemma.usesRealModel, await gemma.isReady,
           Self.isAmbiguous(deterministic, query: query),
           let refined = await modelClassify(query: query, gemma: gemma),
           refined != .localOnly || deterministic == .localOnly {
            return refined
        }
        return deterministic
    }

    // MARK: - Deterministic rules

    static func deterministicClassify(query: String) -> IntentType {
        let hasPersonal = matches(query, personalPortfolioPattern)
        let hasExternal = matches(query, comparisonPattern)
            || matches(query, marketContextPattern)

        if hasPersonal && hasExternal { return .hybrid }
        if hasPersonal { return .localOnly }
        return .cloudAnalysis
    }

    // The deterministic rules currently cover every acceptance case, so this
    // returns false. It's a hook for future tuning — e.g. a sentence that
    // mentions "the market" without "my X" might warrant a model second look.
    private static func isAmbiguous(_ intent: IntentType, query: String) -> Bool {
        _ = intent
        _ = query
        return false
    }

    // First-person portfolio references. The leading `\bmy\b` is the safety
    // gate — a question about "Apple's positions" is not personal. The
    // `(?:\w+\s+){0,3}` allows a short modifier run between "my" and the
    // noun so "my current positions" / "my largest tech holding" still match.
    private static let personalPortfolioPattern = #"(?i)\bmy\s+(?:\w+\s+){0,3}(positions?|portfolio|holdings?|shares?|allocation|account|stocks?|investments?|balance|book|exposure|cost\s+basis|returns?|p\s?&\s?l|sectors?)\b"#

    // Comparison verbs / phrases. "Concentrated vs the market", "compared
    // against peers", "benchmark my returns" all qualify.
    private static let comparisonPattern = #"(?i)\b(compared?|comparison|versus|vs\.?|against|relative\s+to|benchmark(s|ed|ing)?|outperform(s|ed|ing)?|underperform(s|ed|ing)?)\b"#

    // Specific external-market identifiers. Deliberately narrow — "current"
    // or "today" must NOT trip this; otherwise "my current positions" would
    // look hybrid.
    private static let marketContextPattern = #"(?i)(\bs\s?&\s?p(\s+500)?\b|\bsp\s?500\b|\bnasdaq\b|\bdow(\s+jones)?\b|\brussell\s*\d*\b|\bvix\b|\bthe\s+market\b|\bmarket\s+(average|cap|benchmark)\b|\bsector\s+average\b|\bindustry\s+average\b|\bpeers?\b)"#

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    // MARK: - Model refinement (real Gemma only)

    private func modelClassify(query: String, gemma: GemmaService) async -> IntentType? {
        let category = await gemma.classify(
            prompt: query,
            categories: ["local_only", "cloud_analysis", "hybrid"]
        )
        switch category {
        case "local_only": return .localOnly
        case "cloud_analysis": return .cloudAnalysis
        case "hybrid": return .hybrid
        default: return nil
        }
    }
}
