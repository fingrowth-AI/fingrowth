import Foundation

// Presentation logic for an analysis result (V10-02).
//
// The result must open on a short, readable conclusion that addresses the
// user's actual question — not a table of indicators. The indicator table is
// demoted to supporting evidence the user can expand below. This type holds the
// view-independent decisions so they're unit-testable; ResearchView renders in
// the order this implies.
// Semantic tone for a signal-at-a-glance pill. View maps these to colors
// (amber = caution / stretched, green = positive momentum, gray = neutral).
enum SignalTone: Equatable, Sendable {
    case caution
    case positive
    case neutral
}

// A compact summary of one interpretive signal already computed in the
// indicator card (RSI state, MACD direction, price-vs-bands), surfaced as a
// colored pill near the top of the result.
struct SignalPill: Equatable, Sendable, Identifiable {
    let indicator: String  // "RSI", "MACD", "Bands"
    let state: String      // "Overbought", "Bullish", "Within", …
    let tone: SignalTone
    var id: String { indicator }
}

// One scannable chunk of the result narrative: a short header plus either
// bullets (discrete items — headlines, individual signal reads) or a short
// prose body. Never both.
struct NarrativeSection: Equatable, Sendable, Identifiable {
    let header: String
    let bullets: [String]
    let prose: String
    var id: String { header }

    init(header: String, bullets: [String] = [], prose: String = "") {
        self.header = header
        self.bullets = bullets
        self.prose = prose
    }
}

// The chat-style decomposition of a result's text: one plain-language takeaway
// line on top, then progressively-disclosed sections below — never a single
// multi-sentence wall. Presentation only: every word comes from the backend
// narrative/verdict or the already-received news items, reorganized.
struct ResultPresentation: Equatable, Sendable {
    let takeaway: String
    let sections: [NarrativeSection]
}

enum AnalysisResultPresenter {
    // Indicators are supporting evidence shown *below* the assessment, collapsed
    // by default so a result never opens on a number dump (V10-02 AC1/AC3).
    static let indicatorsInitiallyExpanded = false

    // The one-line verdict shown at the very top of a result. Uses the backend's
    // deterministic verdict when present; otherwise falls back to the V10-02 lead
    // assessment (e.g. the general route, which has no indicator-derived verdict).
    static func verdictLine(verdict: String, narrative: String, query: String) -> String {
        let trimmed = verdict.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? leadAssessment(narrative: narrative, query: query) : trimmed
    }

    // Derive the signal-at-a-glance pills from the same computed indicators the
    // card shows — same thresholds as IndicatorFormatter's tags. Deterministic;
    // only emits a pill for an indicator that's actually present.
    static func signalPills(from technical: [String: JSONValue]) -> [SignalPill] {
        var pills: [SignalPill] = []

        if let rsi = number(technical["rsi"]) {
            if rsi >= 70 {
                pills.append(SignalPill(indicator: "RSI", state: "Overbought", tone: .caution))
            } else if rsi <= 30 {
                pills.append(SignalPill(indicator: "RSI", state: "Oversold", tone: .caution))
            } else {
                pills.append(SignalPill(indicator: "RSI", state: "Neutral", tone: .neutral))
            }
        }

        if case .object(let macd)? = technical["macd"], let histogram = number(macd["histogram"]) {
            if histogram > 0 {
                pills.append(SignalPill(indicator: "MACD", state: "Bullish", tone: .positive))
            } else if histogram < 0 {
                pills.append(SignalPill(indicator: "MACD", state: "Bearish", tone: .caution))
            } else {
                pills.append(SignalPill(indicator: "MACD", state: "Flat", tone: .neutral))
            }
        }

        if case .object(let bands)? = technical["bollinger"],
           let close = number(technical["latest_close"]),
           let upper = number(bands["upper"]),
           let lower = number(bands["lower"]) {
            if close > upper {
                pills.append(SignalPill(indicator: "Bands", state: "Above", tone: .caution))
            } else if close < lower {
                pills.append(SignalPill(indicator: "Bands", state: "Below", tone: .caution))
            } else {
                pills.append(SignalPill(indicator: "Bands", state: "Within", tone: .neutral))
            }
        }

        return pills
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    // Whether the question asks about future direction or a buy/sell decision,
    // rather than a factual or indicator lookup. Directional questions earn the
    // honest "no one can reliably predict" framing (AC2).
    static func isDirectionalQuestion(_ query: String) -> Bool {
        let q = query.lowercased()
        let cues = [
            "will ", "going to", "go up", "go down", "gonna", "rise", "rally",
            "fall", "drop", "crash", "moon", "should i buy", "should i sell",
            "should i hold", "is it a buy", "is it a sell", "good time to buy",
            "good time to sell", "worth buying", "worth selling", "predict",
            "forecast", "outlook", "price target", "headed", "next week",
            "next month", "tomorrow",
        ]
        return cues.contains { q.contains($0) }
    }

    // The plain-language conclusion shown at the TOP of a result. Leads with the
    // analyst narrative (V10-01). For a directional question it guarantees the
    // honest no-prediction framing is present even if the narrative didn't spell
    // it out — never a bare number dump. Falls back to a readable line when the
    // narrative is empty (e.g. a degraded result), pointing at the evidence below.
    static func leadAssessment(narrative: String, query: String) -> String {
        let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? "We couldn't produce an assessment for this question — the supporting "
                + "indicators are below."
            : trimmed
        guard isDirectionalQuestion(query) else { return base }
        // Avoid double-hedging: the V10-01 narrative usually already states that
        // no single indicator predicts direction.
        if base.lowercased().contains("predict") {
            return base
        }
        return "No one can reliably predict where the price goes next, but here's "
            + "what the signals suggest. " + base
    }

    // MARK: - Narrative decomposition (chat-style sections)

    // The marker sentence the general-research narrator emits before listing
    // headlines inline. Replaced by a structured "In the news" list.
    private static let headlinesMarker = "Headlines reportedly in focus"

    // Sentences that are framing rather than findings — surfaced under a
    // "Context" header instead of mixed into the read.
    private static let contextPrefixes = [
        "Note:", "Context:", "Portfolio context:", "Prior context:",
    ]
    private static let contextPhrases = [
        "not advice", "not a recommendation", "informational purposes",
    ]

    // Decompose a result's text into a one-line takeaway plus scannable
    // sections, for all three analysis types:
    //   * takeaway — the backend verdict when present (technical/fundamental),
    //     otherwise the narrative's first sentence (general), hedged for a
    //     directional question exactly like leadAssessment.
    //   * "In the news" — the narrator's inline headline listing, expanded to
    //     one bullet per headline. `newsHeadlines` (the structured items from
    //     the research packet) is preferred; the marker sentence is parsed as
    //     a fallback for persisted history entries that kept only the prose.
    //   * "Detail" — the remaining findings, one bullet per sentence.
    //   * "Context" — framing sentences (degraded-source notes, the inline
    //     research-not-advice line) as short prose.
    static func presentation(
        verdict: String,
        narrative: String,
        query: String,
        newsHeadlines: [String] = []
    ) -> ResultPresentation {
        let trimmedVerdict = verdict.trimmingCharacters(in: .whitespacesAndNewlines)
        let (body, markerHeadlines) = extractHeadlinesMarker(from: narrative)
        var sentences = split(sentences: body)

        let takeaway: String
        if !trimmedVerdict.isEmpty {
            takeaway = trimmedVerdict
        } else if let first = sentences.first {
            sentences.removeFirst()
            // Same honest-framing rule as leadAssessment, applied to the
            // one-line lead rather than the whole narrative.
            if isDirectionalQuestion(query), !narrative.lowercased().contains("predict") {
                takeaway = "No one can reliably predict where the price goes next, "
                    + "but here's what the signals suggest. " + first
            } else {
                takeaway = first
            }
        } else {
            takeaway = leadAssessment(narrative: narrative, query: query)
        }

        var sections: [NarrativeSection] = []

        // Structured headlines win (exact strings from the research packet);
        // the parsed marker sentence covers prose-only callers. Either way the
        // section only appears when the narrative actually flagged headlines —
        // this stays a reorganization, never an addition.
        if markerHeadlines != nil {
            let headlines = newsHeadlines.isEmpty ? (markerHeadlines ?? []) : newsHeadlines
            if !headlines.isEmpty {
                sections.append(NarrativeSection(header: "In the news", bullets: headlines))
            }
        }

        let detail = sentences.filter { !isContextSentence($0) }
        if !detail.isEmpty {
            sections.append(NarrativeSection(header: "Detail", bullets: detail))
        }
        let context = sentences.filter { isContextSentence($0) }
        if !context.isEmpty {
            sections.append(NarrativeSection(header: "Context", prose: context.joined(separator: " ")))
        }

        return ResultPresentation(takeaway: takeaway, sections: sections)
    }

    // Headline strings from the research packet's raw news items, for the
    // "In the news" bullets.
    static func headlines(from news: [JSONValue], limit: Int = 5) -> [String] {
        news.prefix(limit).compactMap { item in
            guard case .object(let fields) = item,
                  let headline = fields["headline"]?.asString else { return nil }
            let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func isContextSentence(_ sentence: String) -> Bool {
        if contextPrefixes.contains(where: { sentence.hasPrefix($0) }) { return true }
        let lowered = sentence.lowercased()
        return contextPhrases.contains { lowered.contains($0) }
    }

    // Remove the narrator's inline "Headlines reportedly in focus: “a”; “b”."
    // segment from the narrative and return the headlines it carried. Cut at
    // the closing-quote-period so a period *inside* a headline doesn't truncate
    // the segment early; without one, the cut falls back to the next sentence
    // break, then to the end of the text.
    private static func extractHeadlinesMarker(from narrative: String) -> (String, [String]?) {
        guard let markerRange = narrative.range(of: headlinesMarker) else {
            return (narrative, nil)
        }
        let tail = narrative[markerRange.upperBound...]
        let segmentEnd = tail.range(of: "”.")?.upperBound
            ?? tail.range(of: ". ")?.upperBound
            ?? narrative.endIndex
        let segment = narrative[markerRange.lowerBound..<segmentEnd]

        var remainder = narrative
        remainder.removeSubrange(markerRange.lowerBound..<segmentEnd)
        let cleaned = remainder
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // "…in focus: “a”; “b”; “c”." → ["a", "b", "c"]
        let listing = segment.drop(while: { $0 != ":" }).dropFirst()
        let quoteAndSpace = CharacterSet(charactersIn: "“”\" .;")
        let headlines = listing
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: quoteAndSpace) }
            .filter { !$0.isEmpty }
        return (cleaned, headlines)
    }

    // Split prose into sentences at . ! ? followed by whitespace. Decimal
    // points (e.g. "72.10") have no trailing whitespace, so values quoted by
    // the analyst narrative never split a sentence.
    private static func split(sentences text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if let previous, ".!?".contains(previous), character.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
            current.append(character)
            previous = character
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }
}
