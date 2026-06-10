import Foundation

// V12-04: auto-classify the analysis type from a natural-language query.
//
// Most users don't know the difference between Fundamental / Technical /
// General, so the app should infer it from how the question is phrased and
// pre-select the right path — while still letting the user override.
//
// Mirrors IntentRouter (P5-07): a deterministic keyword pass is the floor so the
// classification is reproducible and testable, and a loaded on-device Gemma may
// refine the genuinely ambiguous cases. Everything runs on-device; no network.
struct AnalysisTypeClassifier: Sendable {
    let gemma: GemmaService?

    init(gemma: GemmaService? = nil) {
        self.gemma = gemma
    }

    /// Classify `query` into a Fundamental / Technical / General path. Never
    /// throws; the deterministic result is always the floor.
    func classify(query: String) async -> AnalysisType {
        let deterministic = Self.deterministicClassify(query: query)

        // Only consult the model when the rules found no clear signal *and* the
        // real model is loaded — otherwise the deterministic read stands. The
        // model can only refine an ambiguous (.general) read, never override a
        // confident technical/fundamental one.
        if let gemma, await gemma.usesRealModel, await gemma.isReady,
           Self.isAmbiguous(deterministic),
           let refined = await modelClassify(query: query, gemma: gemma) {
            return refined
        }
        return deterministic
    }

    // MARK: - Deterministic rules

    /// Score technical vs. fundamental cues; the side with more distinct hits
    /// wins, and a tie (or no cues at all) falls back to General.
    static func deterministicClassify(query: String) -> AnalysisType {
        let technical = score(technicalPatterns, in: query)
        let fundamental = score(fundamentalPatterns, in: query)
        if technical > fundamental { return .technical }
        if fundamental > technical { return .fundamental }
        return .general
    }

    /// Only an inconclusive (.general) read is worth a model second look; a
    /// confident technical/fundamental classification is trusted as-is.
    static func isAmbiguous(_ type: AnalysisType) -> Bool {
        type == .general
    }

    // Chart/price-action vocabulary → Technical.
    private static let technicalCues = [
        "rsi", "macd", "bollinger", "moving average", "sma", "ema", "overbought",
        "oversold", "momentum", "support", "resistance", "trend", "trending",
        "breakout", "technical", "chart", "charts", "candlestick", "death cross",
        "golden cross", "50-day", "200-day", "price action", "volume",
    ]

    // Company-financials vocabulary → Fundamental.
    private static let fundamentalCues = [
        "earnings", "revenue", "p/e", "pe ratio", "valuation", "valued", "value",
        "balance sheet", "cash flow", "fundamental", "fundamentals", "debt",
        "margin", "margins", "dividend", "eps", "book value", "10-k", "10-q",
        "filing", "filings", "income statement", "profit", "profits", "guidance",
        "moat", "financials", "sales", "growth", "quarter", "quarterly",
        "net income", "outlook",
    ]

    private static let technicalPatterns = makePatterns(technicalCues)
    private static let fundamentalPatterns = makePatterns(fundamentalCues)

    // Word-bounded so short cues ("sma", "ema", "eps") don't match inside other
    // words ("smart", "theme", "steps"). Compiled once.
    private static func makePatterns(_ cues: [String]) -> [NSRegularExpression] {
        cues.compactMap {
            try? NSRegularExpression(
                pattern: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#,
                options: [.caseInsensitive]
            )
        }
    }

    // Number of *distinct* cues from the set that appear in the text.
    private static func score(_ patterns: [NSRegularExpression], in text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.reduce(into: 0) { count, regex in
            if regex.firstMatch(in: text, range: range) != nil { count += 1 }
        }
    }

    // MARK: - Model refinement (real Gemma only)

    private func modelClassify(query: String, gemma: GemmaService) async -> AnalysisType? {
        let category = await gemma.classify(
            prompt: query,
            categories: AnalysisType.allCases.map(\.rawValue)
        )
        return AnalysisType(rawValue: category)
    }
}
