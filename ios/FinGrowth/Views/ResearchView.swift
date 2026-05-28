import SwiftUI
import SwiftData

// P4-03 Research surface. Composes the streaming pipeline from P4-02 with a
// ticker autocomplete, progress stages, expandable formatted sections
// (Technical / Summary / Risk), persisted history, and a "Test with paper
// trade" action that hands the ticker to the Portfolio tab via
// PaperTradePrefill.
struct ResearchView: View {
    let apiClient: APIClient
    let paperTradePrefill: PaperTradePrefill
    let onSwitchToPortfolio: () -> Void
    let gemma: GemmaService
    let settings: AppSettings

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ResearchHistoryEntry.createdAt, order: .reverse)
    private var history: [ResearchHistoryEntry]
    @Query(sort: \PrivateLedger.importedAt, order: .reverse)
    private var ledgers: [PrivateLedger]
    @Query(sort: \ShareableProfile.generatedAt, order: .reverse)
    private var profiles: [ShareableProfile]

    @State private var controller: AnalysisStreamController?
    // In-flight intent routing for the current Run. Stored so a second tap (or
    // an edit + re-tap) while classification/rewrite/audit is still awaiting
    // cancels the older run — otherwise a stale task could fire an extra cloud
    // request and write a duplicate audit row, breaking the one-call/one-entry
    // invariant. The Run button can't guard this on its own because
    // controller.start (which flips isRunning) only happens after the awaits.
    @State private var routingTask: Task<Void, Never>?
    @State private var query: String = ""
    @State private var ticker: String = ""
    @State private var analysisType: AnalysisType = .technical
    @State private var showSuggestions: Bool = false
    @State private var lastPersistedSessionID: UUID?
    // Session ID of the last-saved history entry — used to link a paper
    // trade back to the analysis that inspired it (P4-04). UUID rather than
    // PersistentIdentifier because SwiftData rejects PersistentIdentifier as
    // a stored attribute on PaperTradeRecord.
    @State private var lastPersistedSessionLinkID: UUID?
    @State private var selectedHistoryEntry: ResearchHistoryEntry?
    @State private var auditErrorMessage: String?
    @State private var localOnlyMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    // Wire names mirror backend/app/routers/analysis.py — progress frames emit
    // "researching" / "analyzing" / "reviewing" — paired with the label shown
    // in the stage indicator row.
    private static let stages: [(wire: String, label: String)] = [
        ("researching", "Research"),
        ("analyzing", "Analysis"),
        ("reviewing", "Review"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                MarketBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        researchHeader
                        querySection
                        if let auditErrorMessage {
                            errorBanner(message: auditErrorMessage)
                        }
                        if let localOnlyMessage {
                            localOnlyBanner(message: localOnlyMessage)
                        }
                        if let controller {
                            progressSection(controller: controller)
                            resultSection(controller: controller)
                            if let message = controller.errorMessage {
                                errorBanner(message: message)
                            }
                        }
                        historySection
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 28)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Research")
            .onAppear { ensureController() }
            .onChange(of: controller?.finalResult) { _, newValue in
                persistIfNeeded(newValue)
            }
            .sheet(item: $selectedHistoryEntry) { entry in
                HistoryDetailSheet(entry: entry) { ticker in
                    enqueuePaperTrade(
                        ticker: ticker,
                        sourceQuery: entry.query,
                        sourceAnalysisType: entry.analysisType,
                        sourceConfidence: entry.confidence,
                        sourceResearchSessionID: entry.sessionID
                    )
                    selectedHistoryEntry = nil
                }
            }
        }
    }

    // MARK: - Query

    private var researchHeader: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(FinTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(FinTheme.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Research")
                            .font(.title2.weight(.bold))
                        Text("Ask, stream, and review market context.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    statusPill("On-device PII", systemImage: "lock.fill", color: FinTheme.mint)
                    statusPill("Research only", systemImage: "doc.text.magnifyingglass", color: FinTheme.amber)
                }
            }
        }
        .padding(.top, 8)
    }

    private var querySection: some View {
        Card(title: "Query") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Ask a question", text: $query, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(FinTheme.field(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                tickerField

                Picker("Type", selection: $analysisType) {
                    ForEach(AnalysisType.allCases) { type in
                        Text(type.rawValue.capitalized).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(action: run) {
                        Label("Run analysis", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)

                    if controller?.isRunning == true {
                        Button(role: .destructive, action: { controller?.cancel() }) {
                            Label("Cancel", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("Streams from the backend configured in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tickerField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ticker (e.g. AAPL)", text: $ticker)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .font(.headline.monospaced())
                .padding(12)
                .background(FinTheme.field(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: ticker) { _, _ in showSuggestions = true }
                .onSubmit { showSuggestions = false }

            if showSuggestions {
                let suggestions = TickerCatalog.suggestions(
                    for: ticker,
                    recents: recentTickers()
                )
                if !suggestions.isEmpty {
                    suggestionList(suggestions)
                }
            }
        }
    }

    private func suggestionList(_ entries: [TickerCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                Button {
                    ticker = entry.symbol
                    showSuggestions = false
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 64, alignment: .leading)
                        Text(entry.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if entry != entries.last {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .background(FinTheme.panel(for: colorScheme))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FinTheme.border(for: colorScheme), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var canSubmit: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !ticker.trimmingCharacters(in: .whitespaces).isEmpty
            && controller?.isRunning != true
    }

    // MARK: - Progress

    private func progressSection(controller: AnalysisStreamController) -> some View {
        Card(title: "Progress") {
            VStack(alignment: .leading, spacing: 12) {
                statusLine(controller: controller)
                stageDots(controller: controller)
            }
        }
    }

    @ViewBuilder
    private func statusLine(controller: AnalysisStreamController) -> some View {
        switch controller.phase {
        case .idle:
            Label("Idle", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(stageLabel(for: stage) + "…")
                    .font(.subheadline)
            }
        case .completed:
            Label("Analysis complete", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func stageDots(controller: AnalysisStreamController) -> some View {
        let seen = Set(controller.stages.map { $0.lowercased() })
        let currentStage: String? = {
            if case .running(let stage) = controller.phase {
                return stage.lowercased()
            }
            return nil
        }()
        // A stage is "done" once a later stage is in flight or the run has
        // completed — the wire only flips once per phase, so the current
        // stage is reported as `seen` while it's still in progress.
        let completedRun: Bool = {
            if case .completed = controller.phase { return true }
            return false
        }()
        return HStack(spacing: 12) {
            ForEach(Array(Self.stages.enumerated()), id: \.element.wire) { index, stage in
                let isCurrent = currentStage == stage.wire
                let laterSeen = Self.stages.dropFirst(index + 1).contains { seen.contains($0.wire) }
                let isDone = completedRun || laterSeen
                HStack(spacing: 6) {
                    Image(systemName: isDone
                          ? "checkmark.circle.fill"
                          : (isCurrent ? "circle.dotted" : "circle"))
                        .foregroundStyle(isDone ? .green : (isCurrent ? .accentColor : .secondary))
                    Text(stage.label)
                        .font(.caption)
                        .foregroundStyle(isDone || isCurrent ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultSection(controller: AnalysisStreamController) -> some View {
        if let final = controller.finalResult {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: "Result · \(final.ticker)") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(final.analysis.confidence.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(confidenceColor(final.analysis.confidence).opacity(0.15))
                            .foregroundStyle(confidenceColor(final.analysis.confidence))
                            .clipShape(Capsule())
                        Spacer()
                        Button {
                            enqueuePaperTrade(
                                ticker: final.ticker,
                                sourceQuery: query,
                                sourceAnalysisType: analysisType,
                                sourceConfidence: final.analysis.confidence,
                                sourceResearchSessionID: lastPersistedSessionLinkID
                            )
                        } label: {
                            Label("Test with paper trade", systemImage: "arrow.right.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                expandableSection(
                    title: "Technical Indicators",
                    systemImage: "chart.xyaxis.line",
                    initiallyExpanded: true
                ) {
                    TechnicalIndicatorsView(indicators: final.analysis.technical)
                }

                expandableSection(
                    title: "Summary",
                    systemImage: "text.alignleft",
                    initiallyExpanded: true
                ) {
                    Text(final.analysis.narrative.isEmpty
                         ? "(no narrative returned)"
                         : final.analysis.narrative)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                expandableSection(
                    title: "Risk Assessment",
                    systemImage: "shield.lefthalf.filled",
                    initiallyExpanded: !final.riskReview.flags.isEmpty
                ) {
                    RiskReviewView(review: final.riskReview)
                }

                Text(final.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        } else if controller.partialAnalysis != nil || controller.research != nil {
            Card(title: "Partial result") {
                VStack(alignment: .leading, spacing: 8) {
                    if let research = controller.research {
                        Text("Research: \(research.filings.count) filings, \(research.news.count) news items")
                            .font(.footnote)
                    }
                    if let partial = controller.partialAnalysis {
                        Text("Confidence: \(partial.confidence)")
                            .font(.footnote)
                        if !partial.technical.isEmpty {
                            Text("Indicators: \(partial.technical.keys.sorted().joined(separator: ", "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func expandableSection<Content: View>(
        title: String,
        systemImage: String,
        initiallyExpanded: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ExpandableCard(
            title: title,
            systemImage: systemImage,
            initiallyExpanded: initiallyExpanded,
            content: content
        )
    }

    private func errorBanner(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .padding(12)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func localOnlyBanner(message: String) -> some View {
        Label(message, systemImage: "lock.shield")
            .font(.subheadline)
            .padding(12)
            .background(FinTheme.mint.opacity(0.12))
            .foregroundStyle(FinTheme.mint)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            Card(title: "History") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(history.prefix(10)) { entry in
                        Button {
                            selectedHistoryEntry = entry
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.ticker)
                                        .font(.subheadline.weight(.semibold))
                                    Text(entry.query)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(entry.createdAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if entry != history.prefix(10).last {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func recentTickers() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in history {
            let upper = entry.ticker.uppercased()
            if seen.insert(upper).inserted {
                result.append(upper)
                if result.count >= 5 { break }
            }
        }
        return result
    }

    // MARK: - Actions

    private func ensureController() {
        if controller == nil {
            controller = AnalysisStreamController(client: apiClient)
        }
    }

    private func run() {
        ensureController()
        showSuggestions = false
        auditErrorMessage = nil
        localOnlyMessage = nil
        // Drop any link to the previous analysis. persistIfNeeded reassigns
        // these once the new result is saved; until then the "Test with paper
        // trade" button must not attach a trade to a stale session.
        lastPersistedSessionID = nil
        lastPersistedSessionLinkID = nil

        let rawQuery = query.trimmingCharacters(in: .whitespaces)
        let tickerSymbol = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        let type = analysisType
        let context = modelContext
        let rewriter = QueryRewriter(gemma: gemma)
        let router = IntentRouter(gemma: gemma)
        let ledger = ledgers.first
        let profile = profiles.first
        let privacyLevel = settings.portfolioPrivacyLevel

        // Intent routing (P5-07): classify the query first, then run the
        // pipeline the intent calls for. localOnly never contacts the cloud;
        // hybrid runs both QueryRewriter and Differential Privacy before the
        // call; cloudAnalysis runs only the rewriter. The classifier is
        // deterministic, so the privacy gate stays auditable.
        // Supersede any routing still in flight from a prior tap before
        // starting this one — the older task must not record an audit row or
        // start a cloud request once a newer Run has begun.
        routingTask?.cancel()
        routingTask = Task { @MainActor in
            let intent = await router.classify(query: rawQuery)
            if Task.isCancelled { return }

            if intent == .localOnly {
                // Acceptance: no cloud call for a portfolio-only question.
                // The Portfolio tab is the source of truth — point the user
                // there rather than fabricating an answer here. Local response
                // generation lands in P5-08.
                localOnlyMessage = "This question can be answered from your on-device portfolio — open the Portfolio tab to view it. No cloud request was made."
                // clear() (not cancel()) so the previous run's results don't
                // linger on screen next to the "No cloud request" banner.
                controller?.clear()
                return
            }

            // Rewrite ON-DEVICE *before* anything leaves the device, then send the
            // rewritten text — so the cloud (and the audit log) only ever see the
            // generalized query. The ticker symbol is public, not PII.
            let rewritten = await rewriter.rewrite(query: rawQuery, ledger: ledger)
            if Task.isCancelled { return }

            // Hybrid is the only intent that earns generalized portfolio
            // context: a pure market question (.cloudAnalysis) ships without
            // a profile so we don't leak personal weights on an unrelated
            // query. When no ShareableProfile exists yet, the call still goes
            // out — without profile context — so the user isn't blocked on
            // having imported a CSV.
            let generalized: GeneralizedProfile? = (intent == .hybrid && profile != nil)
                ? DifferentialPrivacy.generalize(profile: profile!, privacyLevel: privacyLevel)
                : nil

            // Record exactly one audit entry of what is actually sent. Recording
            // before transmission keeps the log honest even if the stream fails.
            // If persistence fails, abort: the strict invariant is that every
            // cloud call corresponds to exactly one AuditEntry, so an unlogged
            // request must not leave the device.
            do {
                try PrivacyAuditLog(context: context).record(
                    original: rawQuery,
                    rewritten: rewritten.rewrittenText,
                    profile: generalized,
                    substitutions: rewritten.substitutions,
                    confidence: rewritten.confidenceScore
                )
            } catch {
                assertionFailure("Privacy audit failed to persist: \(error)")
                auditErrorMessage = "Couldn't record this request in the Privacy Audit Log, so it wasn't sent. Please try again."
                return
            }

            let request = AnalysisQuery(
                query: rewritten.rewrittenText,
                ticker: tickerSymbol,
                analysisType: type
            )
            controller?.start(query: request, profile: generalized.map(Self.wireProfile))
        }
    }

    // Project the on-device GeneralizedProfile into the cloud wire shape. The
    // riskScore (a 0…1 number) is bucketed to a generalized string label so
    // the wire payload never carries the raw score.
    private static func wireProfile(_ generalized: GeneralizedProfile) -> PortfolioProfile {
        PortfolioProfile(
            sectorWeights: generalized.sectorWeights,
            largestPosition: generalized.largestPosition,
            diversification: generalized.diversification,
            riskOrientation: generalized.riskScore.map(riskOrientationLabel)
        )
    }

    private static func riskOrientationLabel(_ score: Double) -> String {
        switch score {
        case ..<0.34: return "conservative"
        case ..<0.67: return "balanced"
        default: return "aggressive"
        }
    }

    private func persistIfNeeded(_ response: AnalysisResponse?) {
        guard let response else { return }
        guard lastPersistedSessionID != response.sessionId else { return }
        let request = AnalysisQuery(
            query: query.trimmingCharacters(in: .whitespaces),
            ticker: response.ticker,
            analysisType: analysisType
        )
        let entry = ResearchHistoryEntry.from(query: request, response: response)
        modelContext.insert(entry)
        do {
            try modelContext.save()
            lastPersistedSessionID = response.sessionId
            lastPersistedSessionLinkID = entry.sessionID
        } catch {
            // History persistence is best-effort; surface failure as a footnote
            // rather than blocking the result render.
            assertionFailure("Failed to persist research history: \(error)")
        }
    }

    private func enqueuePaperTrade(
        ticker: String,
        sourceQuery: String,
        sourceAnalysisType: AnalysisType,
        sourceConfidence: String,
        sourceResearchSessionID: UUID? = nil
    ) {
        paperTradePrefill.enqueue(.init(
            ticker: ticker.uppercased(),
            sourceQuery: sourceQuery,
            sourceAnalysisType: sourceAnalysisType,
            sourceConfidence: sourceConfidence,
            sourceResearchSessionID: sourceResearchSessionID
        ))
        onSwitchToPortfolio()
    }

    private func stageLabel(for wire: String) -> String {
        let normalized = wire.lowercased()
        if let match = Self.stages.first(where: { $0.wire == normalized }) {
            return match.label
        }
        return wire.capitalized
    }

    private func confidenceColor(_ value: String) -> Color {
        switch value.lowercased() {
        case "high": return .green
        case "moderate", "medium": return .orange
        case "low": return .red
        default: return .secondary
        }
    }
}

// MARK: - Reusable cards

private struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content
            }
        }
    }
}

private struct ExpandableCard<Content: View>: View {
    let title: String
    let systemImage: String
    let initiallyExpanded: Bool
    let content: Content

    @State private var expanded: Bool

    init(
        title: String,
        systemImage: String,
        initiallyExpanded: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.initiallyExpanded = initiallyExpanded
        self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack {
                        Label(title, systemImage: systemImage)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    content
                }
            }
        }
    }
}

private func statusPill(_ title: String, systemImage: String, color: Color) -> some View {
    Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.14))
        .foregroundStyle(color)
        .clipShape(Capsule())
}

// MARK: - Section bodies

private struct TechnicalIndicatorsView: View {
    let indicators: [String: JSONValue]

    var body: some View {
        if indicators.isEmpty {
            Text("No indicator data returned.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(indicators.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline) {
                        Text(key.uppercased())
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(format(indicators[key]))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func format(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .null: return "—"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            return String(format: "%.2f", d)
        case .string(let s): return s
        case .array(let arr): return "[\(arr.count) values]"
        case .object: return "{…}"
        }
    }
}

private struct RiskReviewView: View {
    let review: RiskReview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                review.approved ? "Approved" : "Modified for safety",
                systemImage: review.approved ? "checkmark.shield" : "exclamationmark.shield"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(review.approved ? .green : .orange)

            if !review.flags.isEmpty {
                ForEach(review.flags, id: \.self) { flag in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flag.code)
                            .font(.caption.weight(.semibold))
                        Text(flag.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if !review.modifiedResponse.isEmpty {
                Text(review.modifiedResponse)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - History detail

private struct HistoryDetailSheet: View {
    let entry: ResearchHistoryEntry
    let onTestPaperTrade: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.query)
                        .font(.body)
                    Text("Confidence: \(entry.confidence)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !entry.narrative.isEmpty {
                        Text(entry.narrative)
                            .font(.body)
                    }
                    if !entry.indicators.isEmpty {
                        Divider()
                        Text("Technical Indicators").font(.headline)
                        TechnicalIndicatorsView(indicators: entry.indicators)
                    }
                    if !entry.riskFlags.isEmpty {
                        Divider()
                        Text("Risk").font(.headline)
                        ForEach(entry.riskFlags, id: \.self) { flag in
                            VStack(alignment: .leading) {
                                Text(flag.code).font(.subheadline.weight(.semibold))
                                Text(flag.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(entry.disclaimer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(entry.ticker)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Paper trade") { onTestPaperTrade(entry.ticker) }
                }
            }
        }
    }
}
