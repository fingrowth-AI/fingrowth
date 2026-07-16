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
    // V12-03: paper trades, observed so the *live* result card shows the trades
    // it inspired the moment they're placed (not only via persisted history).
    @Query(sort: \PaperTradeRecord.submittedAt, order: .reverse)
    private var paperTrades: [PaperTradeRecord]

    @State private var controller: AnalysisStreamController?
    // In-flight intent routing for the current Run. Stored so a second tap (or
    // an edit + re-tap) while classification/rewrite/audit is still awaiting
    // cancels the older run — otherwise a stale task could fire an extra cloud
    // request and write a duplicate audit row, breaking the one-call/one-entry
    // invariant. The Run button can't guard this on its own because
    // controller.start (which flips isRunning) only happens after the awaits.
    @State private var routingTask: Task<Void, Never>?
    @State private var query: String = ""
    // V10-02: the question that produced the currently-displayed result, captured
    // when the stream starts. The `query` field stays editable after Run, so the
    // result's plain-language lead must address what was *submitted*, not whatever
    // the user has since typed.
    @State private var submittedQuery: String = ""
    // The analysis type the in-flight run was submitted with, for the pinned
    // query card's route badge (the picker stays editable during a run).
    @State private var submittedType: AnalysisType = .technical
    @State private var ticker: String = ""
    @State private var analysisType: AnalysisType = .technical
    // V12-04: once the user picks the analysis type themselves, stop
    // auto-classifying so their choice sticks. Reset when the query is cleared.
    @State private var analysisTypeUserOverridden = false
    // In-flight on-device classification for the current query text.
    @State private var classificationTask: Task<Void, Never>?
    @State private var showSuggestions: Bool = false
    // Drives the "Ask another question" shortcut: focuses the query field
    // after scrolling back to it, and drops the keyboard when a run starts.
    @FocusState private var queryFocused: Bool
    @State private var lastPersistedSessionID: UUID?
    // Session ID of the last-saved history entry — used to link a paper
    // trade back to the analysis that inspired it (P4-04). UUID rather than
    // PersistentIdentifier because SwiftData rejects PersistentIdentifier as
    // a stored attribute on PaperTradeRecord.
    @State private var lastPersistedSessionLinkID: UUID?
    @State private var selectedHistoryEntry: ResearchHistoryEntry?
    @State private var auditErrorMessage: String?
    @State private var localOnlyMessage: String?
    // P5-08: holdings-specific context mapped on-device from a cloud result.
    // Additive — rendered as its own section, never edited into the analysis.
    @State private var enrichedContext: PersonalizedContext?
    // V11-01: "What this means for you" — the user's real position in the
    // analyzed ticker, resolved on-device. Additive; nil when the ticker isn't held.
    @State private var positionInsight: PositionInsight?
    // V11-03: portfolio-level overview (diversification, sector concentration,
    // overall risk). Computed on-device from the generalized profile for a
    // whole-portfolio question; nil for a single-ticker query.
    @State private var portfolioAnalysis: PortfolioAnalysis?
    // V12-03: a linked trade opened from the current result card.
    @State private var selectedLinkedTrade: PaperTradeRecord?
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
                ScrollViewReader { proxy in
                    ScrollView {
                        // FG spacing rhythm: 16pt screen margins, 12pt between cards.
                        VStack(alignment: .leading, spacing: 12) {
                            researchHeader
                                .id(Self.queryAnchorID)
                            querySection
                            if let auditErrorMessage {
                                errorBanner(message: auditErrorMessage)
                            }
                            if let localOnlyMessage {
                                localOnlyBanner(message: localOnlyMessage)
                            }
                            if let portfolioAnalysis {
                                portfolioAnalysisSection(portfolioAnalysis)
                            }
                            if let controller {
                                progressSection(controller: controller)
                                resultSection(controller: controller)
                                if let message = controller.errorMessage {
                                    errorBanner(message: message)
                                }
                            }
                            researchEmptyState
                            historySection
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 28)
                    }
                    // Shortcut back into the flow: once a result is on screen
                    // (typically scrolled deep into it), one tap returns to the
                    // query card ready for the next question.
                    .overlay(alignment: .bottom) {
                        if showAskAnotherShortcut {
                            askAnotherButton(proxy)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // Tap on any dead space to drop the keyboard (safe here: this is a
            // ScrollView, not a List/Form, so buttons keep their own taps).
            .dismissesKeyboardOnTap()
            // The screens-after header is custom (title + privacy badge), so the
            // system navigation bar stays hidden.
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { ensureController() }
            .onChange(of: controller?.finalResult) { _, newValue in
                persistIfNeeded(newValue)
                recontextualize(newValue)
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
            // V12-03: open a trade linked from the live result card.
            .sheet(item: $selectedLinkedTrade) { trade in
                LinkedAnalysisSheet(trade: trade, modelContext: modelContext)
            }
        }
    }

    // MARK: - Query

    private static let queryAnchorID = "research-query-anchor"

    private var showAskAnotherShortcut: Bool {
        controller?.finalResult != nil
            && controller?.isRunning != true
            && !queryFocused
    }

    // Floating pill above the tab bar: scrolls back to the query card, clears
    // the answered question (keeping the ticker for natural follow-ups), and
    // opens the keyboard — one tap from reading a result to asking the next.
    private func askAnotherButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            query = ""
            analysisTypeUserOverridden = false
            showSuggestions = false
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(Self.queryAnchorID, anchor: .top)
            }
            queryFocused = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.bubble.fill")
                Text("Ask another question")
            }
            .font(.system(size: 14.5, weight: .bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(FinTheme.accent, in: Capsule())
        .foregroundStyle(FinTheme.onAccent)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // Screens-after header: heavy title, green-lock "Private by design" badge,
    // one-line promise underneath. Rendered on the page background, not a card.
    private var researchHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Research")
                    .font(.system(size: 32, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(FinTheme.textPrimary)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FinTheme.accent)
                    Text("Private by design")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FinTheme.textSecondary)
                }
            }
            Text("Ask anything about a stock — answers stay research-only.")
                .font(.subheadline)
                .foregroundStyle(FinTheme.textSecondary)
        }
        .padding(.top, 12)
        .padding(.horizontal, 4)
    }

    private var querySection: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                // Free-form question, set directly on the card like the comp —
                // no nested input well.
                TextField("Ask anything about a stock", text: $query, axis: .vertical)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(FinTheme.textPrimary)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    // Return runs the analysis when it can (questions don't
                    // need newlines), so query → answer is a single keystroke.
                    .submitLabel(.search)
                    .onSubmit { if canSubmit { run() } }
                    .onChange(of: query) { _, newValue in autoClassifyAnalysisType(newValue) }

                tickerField

                // Edge-to-edge hairline separating the question from the controls.
                Rectangle()
                    .fill(FinTheme.line)
                    .frame(height: 1)
                    .padding(.horizontal, -16)

                typeSelector

                runButton

                // V12-05: example queries so a new user isn't facing a blank
                // box. Shown while the query is empty; tapping one fills it (and
                // the type auto-classifies, V12-04).
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    exampleQueries
                }
            }
        }
    }

    // Custom inset segmented control (the comp's #39433D-on-inset segments).
    // V12-04: the type is auto-detected from the question; the AUTO badge marks
    // an auto-classified selection and disappears once the user picks a type
    // themselves (which also makes their choice stick).
    private var typeSelector: some View {
        HStack(spacing: 0) {
            ForEach(AnalysisType.allCases) { type in
                let isSelected = analysisType == type
                Button {
                    analysisType = type
                    analysisTypeUserOverridden = true
                } label: {
                    Text(type.rawValue.capitalized)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? FinTheme.textPrimary : FinTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? FinTheme.segment : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(alignment: .topTrailing) {
                            if isSelected && !analysisTypeUserOverridden {
                                Text("AUTO")
                                    .font(.system(size: 9, weight: .heavy))
                                    .tracking(0.3)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        FinTheme.accent,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .foregroundStyle(FinTheme.onAccent)
                                    .offset(x: 4, y: -7)
                                    .accessibilityLabel("Auto-detected from your question")
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(FinTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Headroom so the AUTO badge can overflow the segment upward.
        .padding(.top, 6)
    }

    // Full-width primary action: solid green with dark-forest content while a
    // run can start; swaps to a Cancel affordance while the stream is live.
    @ViewBuilder
    private var runButton: some View {
        if controller?.isRunning == true {
            Button {
                controller?.cancel()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
                    .font(.system(size: 16.5, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(FinTheme.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .foregroundStyle(FinTheme.textPrimary)
        } else {
            Button(action: run) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Run analysis")
                }
                .font(.system(size: 16.5, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                canSubmit ? FinTheme.accent : FinTheme.inset,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .foregroundStyle(canSubmit ? FinTheme.onAccent : FinTheme.textTertiary)
            .disabled(!canSubmit)
        }
    }

    // V12-05: a guiding empty state shown before the user has any result or
    // history — a friendly welcome plus the privacy framing, pointing at the
    // example queries above.
    @ViewBuilder
    private var researchEmptyState: some View {
        let noResult = controller?.finalResult == nil
            && controller?.partialAnalysis == nil
            && controller?.research == nil
        if noResult && portfolioAnalysis == nil && history.isEmpty
            && localOnlyMessage == nil && auditErrorMessage == nil {
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(FinTheme.accent)
                    Text("Ask your first question")
                        .font(.headline)
                    Text("Type a question above, or tap an example. Your portfolio is processed "
                        + "on-device, and you can see exactly what reaches the cloud in the "
                        + "Privacy tab. This is research, not advice.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var exampleQueries: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Try an example", systemImage: "lightbulb")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(ResearchExamples.all) { example in
                Button {
                    query = example.query
                    // Fill the ticker so single-ticker examples are runnable
                    // immediately; portfolio-level examples (nil) need no ticker.
                    if let exampleTicker = example.ticker { ticker = exampleTicker }
                    autoClassifyAnalysisType(example.query)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(FinTheme.accent)
                        Text(example.query)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FinTheme.field(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
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
                .submitLabel(.go)
                .onSubmit {
                    showSuggestions = false
                    if canSubmit { run() }
                }

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

    // V12-04: classify the analysis type from the query on-device and pre-select
    // it, unless the user has overridden the picker. Clearing the query re-arms
    // auto-detection. Runs on the deterministic floor instantly; an on-device
    // Gemma refine only fires for ambiguous text when the model is loaded.
    private func autoClassifyAnalysisType(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            analysisTypeUserOverridden = false
            classificationTask?.cancel()
            return
        }
        guard !analysisTypeUserOverridden else { return }
        classificationTask?.cancel()
        classificationTask = Task { @MainActor in
            let type = await AnalysisTypeClassifier(gemma: gemma).classify(query: trimmed)
            guard !Task.isCancelled, !analysisTypeUserOverridden else { return }
            // Drop the result if the query moved on while classifying.
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            analysisType = type
        }
    }

    // V12-03: trades placed from the currently displayed result, keyed on the
    // persisted history entry's session ID (what enqueuePaperTrade links to).
    private var linkedTradesForCurrentResult: [PaperTradeRecord] {
        guard let sessionID = lastPersistedSessionLinkID else { return [] }
        return paperTrades.filter { $0.sourceResearchSessionID == sessionID }
    }

    private var canSubmit: Bool {
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // V11-03: a whole-portfolio question has no single ticker, so it doesn't
        // require the ticker field — it's answered on-device from the profile.
        let hasTickerOrIsPortfolio = !ticker.trimmingCharacters(in: .whitespaces).isEmpty
            || PortfolioAnalyzer.isPortfolioLevelQuery(query)
        return hasQuery && hasTickerOrIsPortfolio && controller?.isRunning != true
    }

    // MARK: - Progress

    private enum StageState {
        case done, active, todo
    }

    // Streaming progress per screens-after: a pinned query card, then a
    // vertical timeline (green check = done, spinner = active, outline = todo).
    // Shown only while a run is live or has failed — the result screen replaces
    // it on completion, and the compose screen carries no idle progress card.
    @ViewBuilder
    private func progressSection(controller: AnalysisStreamController) -> some View {
        let visible: Bool = {
            switch controller.phase {
            case .running, .failed: return true
            case .idle, .completed: return false
            }
        }()
        if visible {
            GlassPanel {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(FinTheme.textTertiary)
                    Text("“\(submittedQuery)”")
                        .font(.subheadline.italic())
                        .foregroundStyle(FinTheme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(submittedType.rawValue.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FinTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            FinTheme.inset,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
            }
            GlassPanel {
                stageTimeline(controller: controller)
            }
        }
    }

    private func stageTimeline(controller: AnalysisStreamController) -> some View {
        let seen = Set(controller.stages.map { $0.lowercased() })
        let currentStage: String? = {
            if case .running(let stage) = controller.phase {
                return stage.lowercased()
            }
            return nil
        }()
        let completedRun: Bool = {
            if case .completed = controller.phase { return true }
            return false
        }()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.element.wire) { index, stage in
                // A stage is "done" once a later stage is in flight or the run
                // has completed — the wire only flips once per phase, so the
                // current stage is reported as `seen` while still in progress.
                let laterSeen = Self.stages.dropFirst(index + 1).contains { seen.contains($0.wire) }
                let state: StageState = (completedRun || laterSeen)
                    ? .done
                    : (currentStage == stage.wire ? .active : .todo)
                let isLast = index == Self.stages.count - 1
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 4) {
                        stageBadge(state)
                        if !isLast {
                            Rectangle()
                                .fill(state == .done ? FinTheme.accent.opacity(0.5) : FinTheme.line)
                                .frame(width: 2, height: 26)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.label)
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(state == .todo ? FinTheme.textTertiary : FinTheme.textPrimary)
                        Text(stageDescription(stage.wire, state: state, controller: controller))
                            .font(.caption)
                            .fontWeight(state == .active ? .semibold : .regular)
                            .foregroundStyle(state == .active ? FinTheme.accent : FinTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func stageBadge(_ state: StageState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(FinTheme.onAccent)
                .frame(width: 24, height: 24)
                .background(FinTheme.accent, in: Circle())
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(FinTheme.accent)
                .frame(width: 24, height: 24)
        case .todo:
            Circle()
                .stroke(FinTheme.line, lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }

    // One-line stage descriptions; Research reports the real counts once the
    // packet has streamed in.
    private func stageDescription(
        _ wire: String,
        state: StageState,
        controller: AnalysisStreamController
    ) -> String {
        switch wire {
        case "researching":
            if let research = controller.research {
                return "\(research.news.count) news items · \(research.filings.count) filings found"
            }
            return state == .active ? "Gathering filings & news…" : "Filings & news"
        case "analyzing":
            switch state {
            case .active: return "Scoring technicals & sentiment…"
            case .done: return "Report drafted"
            case .todo: return "Technicals & narrative"
            }
        default:
            return state == .active ? "Checking the risk gate…" : "Risk gate"
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultSection(controller: AnalysisStreamController) -> some View {
        if let final = controller.finalResult {
            // Chat-style decomposition of the result text: one takeaway line,
            // then scannable sections (headlines as bullets, context separated)
            // instead of a single dense paragraph. Same treatment for all three
            // analysis types; reorganization only, the words are the backend's.
            let presentation = AnalysisResultPresenter.presentation(
                verdict: final.analysis.verdict,
                narrative: final.analysis.narrative,
                query: submittedQuery,
                newsHeadlines: AnalysisResultPresenter.headlines(from: final.research.news)
            )
            VStack(alignment: .leading, spacing: 12) {
                // 1. Result header — big ticker + company, freshness, and the
                // confidence dot (the comp's AfConfidence), on the page itself.
                resultHeader(final)

                // 2. Verdict — the 2-second takeaway, leading the result.
                Text(presentation.takeaway)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FinTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                // 3. Stat strip — coverage at a glance.
                statStrip(final)

                // 4. Portfolio-context slot — directly under the verdict. Filled
                // by the V11-01/V11-02 "What this means for you" section when the
                // user holds the analyzed ticker; otherwise empty.
                if let positionInsight {
                    positionInsightSection(positionInsight)
                }

                // 5. What this means — chunked interpretation (no repeated numbers).
                whatThisMeansSection(final.analysis)

                // 6. "What's moving TICKER" — the received headlines as rows with
                // source pills. Supersedes the presenter's plainer "In the news"
                // bullets whenever the structured news items are present.
                let newsRows = headlineRows(from: final.research.news)
                headlinesSection(ticker: final.ticker, rows: newsRows)

                // 6b. The rest of the narrative, decomposed into scannable
                // sections. Inline for the general route, where it *is* the body;
                // collapsed supporting detail when the interpretation chunks
                // above carry the meaning.
                narrativeSections(
                    presentation.sections.filter { newsRows.isEmpty || $0.header != "In the news" },
                    inline: final.analysis.interpretation.isEmpty
                )

                // 7. Technicals — the key signals as a 2-up grid of inset tiles
                // (value + interpretive note), with the chart and the full
                // indicator list as collapsed drill-down below.
                technicalsSection(final.analysis.technical)

                if let bands = BollingerChartModel.make(from: final.analysis.technical) {
                    Card(title: "Price vs. Bollinger Bands") {
                        BollingerBandChart(point: bands)
                    }
                }

                expandableSection(
                    title: "All indicators",
                    systemImage: "chart.xyaxis.line",
                    initiallyExpanded: AnalysisResultPresenter.indicatorsInitiallyExpanded
                ) {
                    TechnicalIndicatorsView(indicators: final.analysis.technical)
                }

                // 8. Risk gate — collapsed; the approve/flag state reads in the
                // compact header rather than as a full section.
                expandableSection(
                    title: final.riskReview.approved ? "Risk gate · Approved" : "Risk gate · Flagged",
                    systemImage: "shield.lefthalf.filled",
                    initiallyExpanded: false
                ) {
                    RiskReviewView(review: final.riskReview)
                }

                if let enrichedContext {
                    personalizedContextSection(enrichedContext)
                }

                // V12-03: trades placed from this analysis appear immediately.
                let linkedTrades = linkedTradesForCurrentResult
                if !linkedTrades.isEmpty {
                    Card(title: "Paper trades from this analysis") {
                        VStack(alignment: .leading, spacing: 8) {
                            LinkedTradesList(trades: linkedTrades) { selectedLinkedTrade = $0 }
                        }
                    }
                }

                // 9. CTA + disclaimer, always at the bottom.
                Button {
                    enqueuePaperTrade(
                        ticker: final.ticker,
                        sourceQuery: query,
                        sourceAnalysisType: analysisType,
                        sourceConfidence: final.analysis.confidence,
                        sourceResearchSessionID: lastPersistedSessionLinkID
                    )
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "flask")
                        Text("Test with paper trade")
                    }
                    .font(.system(size: 16.5, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(FinTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .foregroundStyle(FinTheme.onAccent)
                .padding(.top, 4)

                Text(final.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(FinTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        } else if controller.partialAnalysis != nil || controller.research != nil {
            // Streaming preview: what's already arrived, with shimmer rows
            // standing in for the rest of the report.
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Streaming in")
                    .padding(.horizontal, 4)
                GlassPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        if let research = controller.research {
                            Text("Coverage so far — \(research.news.count) news items and \(research.filings.count) filings.")
                                .font(.subheadline)
                                .foregroundStyle(FinTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let partial = controller.partialAnalysis, !partial.technical.isEmpty {
                            Text("Indicators: \(partial.technical.keys.sorted().map(IndicatorFormatter.humanLabel).joined(separator: ", "))")
                                .font(.footnote)
                                .foregroundStyle(FinTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ShimmerLines()
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

    // Result header: ticker + company name, the data's as-of line, and the
    // confidence dot — rendered on the page background like the comp.
    private func resultHeader(_ final: AnalysisResponse) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(final.ticker)
                        .font(.system(size: 28, weight: .heavy))
                        .tracking(-0.4)
                        .foregroundStyle(FinTheme.textPrimary)
                    if let name = TickerCatalog.name(for: final.ticker) {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(FinTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let freshness = final.research.freshness?.priceDisplay {
                    Label(freshness, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(FinTheme.textTertiary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(confidenceColor(final.analysis.confidence))
                    .frame(width: 7, height: 7)
                Text(final.analysis.confidence.replacingOccurrences(of: "_", with: " ").capitalized
                    + " confidence")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FinTheme.textSecondary)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // Coverage at a glance: news / filings / overall sentiment in one card-style
    // strip with hairline column separators.
    private func statStrip(_ final: AnalysisResponse) -> some View {
        HStack(spacing: 0) {
            statCell(value: "\(final.research.news.count)", label: "News items")
            Rectangle().fill(FinTheme.line).frame(width: 1)
            statCell(value: "\(final.research.filings.count)", label: "Filings")
            Rectangle().fill(FinTheme.line).frame(width: 1)
            statCell(value: sentimentLabel(final.research.news), label: "Sentiment")
        }
        .background(FinTheme.card)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FinTheme.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(FinTheme.textPrimary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FinTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
    }

    // One word for the average tone of the received headlines — display-only
    // bucketing of the packet's own sentiment scores, no new math on the wire.
    private func sentimentLabel(_ news: [JSONValue]) -> String {
        let scores: [Double] = news.compactMap { item in
            guard case .object(let fields) = item else { return nil }
            switch fields["sentiment_score"] {
            case .double(let value): return value
            case .int(let value): return Double(value)
            default: return nil
            }
        }
        guard !scores.isEmpty else { return "—" }
        let mean = scores.reduce(0, +) / Double(scores.count)
        if mean > 0.15 { return "Positive" }
        if mean < -0.15 { return "Negative" }
        return "Mixed"
    }

    // The received news items as headline/source/url rows for the
    // "What's moving TICKER" section.
    private func headlineRows(from news: [JSONValue]) -> [AnalysisResultPresenter.HeadlineItem] {
        AnalysisResultPresenter.headlineItems(from: news, limit: 3)
    }

    @ViewBuilder
    private func headlinesSection(ticker: String, rows: [AnalysisResultPresenter.HeadlineItem]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("What's moving \(ticker)")
                    .padding(.horizontal, 4)
                GlassPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            headlineRow(row)
                                .padding(.top, index == 0 ? 0 : 12)
                                .padding(.bottom, index == rows.count - 1 ? 0 : 12)
                            if index < rows.count - 1 {
                                Rectangle().fill(FinTheme.line).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // One article row. With a validated web URL the whole row is a Link that
    // hands off to the user's default browser (a user action, not an app
    // transmission — so no Privacy Audit Log entry); without one it renders as
    // the same plain, non-tappable row as before.
    @ViewBuilder
    private func headlineRow(_ row: AnalysisResultPresenter.HeadlineItem) -> some View {
        if let url = row.url {
            Link(destination: url) {
                headlineRowContent(row, linked: true)
                    .contentShape(Rectangle())
            }
        } else {
            headlineRowContent(row, linked: false)
        }
    }

    private func headlineRowContent(
        _ row: AnalysisResultPresenter.HeadlineItem, linked: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FinTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if linked {
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FinTheme.textTertiary)
                }
            }
            if let source = row.source, !source.isEmpty {
                Label(source, systemImage: "newspaper")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FinTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        FinTheme.inset,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Technicals grid

    private struct TechnicalTile: Identifiable {
        let label: String
        let value: String
        let note: String
        let tone: Color
        var id: String { label }
    }

    // The key signals as a 2-up grid of inset tiles — value plus interpretive
    // note, same thresholds as the indicator card's tags.
    @ViewBuilder
    private func technicalsSection(_ technical: [String: JSONValue]) -> some View {
        let tiles = technicalTiles(technical)
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Technicals")
                    .padding(.horizontal, 4)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(tiles) { tile in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tile.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FinTheme.textTertiary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(tile.value)
                                    .font(.system(size: 17, weight: .heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(FinTheme.textPrimary)
                                Text(tile.note)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(tile.tone)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(FinTheme.card)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(FinTheme.line, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
    }

    private func technicalTiles(_ technical: [String: JSONValue]) -> [TechnicalTile] {
        var tiles: [TechnicalTile] = []

        if let rsi = numberValue(technical["rsi"]) {
            let note = rsi >= 70 ? "Overbought" : (rsi <= 30 ? "Oversold" : "Neutral")
            let tone = rsi >= 70 || rsi <= 30 ? FinTheme.amber : FinTheme.textSecondary
            tiles.append(TechnicalTile(
                label: "RSI · 14d", value: String(format: "%.0f", rsi), note: note, tone: tone
            ))
        }

        if case .object(let macd)? = technical["macd"], let histogram = numberValue(macd["histogram"]) {
            let note = histogram > 0 ? "Bullish" : (histogram < 0 ? "Bearish" : "Flat")
            let tone = histogram > 0
                ? FinTheme.accent
                : (histogram < 0 ? FinTheme.amber : FinTheme.textSecondary)
            tiles.append(TechnicalTile(
                label: "MACD", value: String(format: "%+.2f", histogram), note: note, tone: tone
            ))
        }

        if case .object(let bands)? = technical["bollinger"],
           let close = numberValue(technical["latest_close"]),
           let upper = numberValue(bands["upper"]),
           let lower = numberValue(bands["lower"]) {
            let value = close > upper ? "High" : (close < lower ? "Low" : "Mid")
            let note = close > upper || close < lower ? "Outside bands" : "Inside bands"
            let tone = close > upper || close < lower ? FinTheme.amber : FinTheme.textSecondary
            tiles.append(TechnicalTile(label: "Bollinger", value: value, note: note, tone: tone))
        }

        if let sma = numberValue(technical["sma_20"]), let close = numberValue(technical["latest_close"]) {
            let above = close > sma
            tiles.append(TechnicalTile(
                label: "20d avg",
                value: String(format: "$%.2f", sma),
                note: above ? "Above avg" : (close < sma ? "Below avg" : "At avg"),
                tone: above ? FinTheme.accent : FinTheme.textSecondary
            ))
        }

        return tiles
    }

    private func numberValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let double): return double
        case .int(let int): return Double(int)
        default: return nil
        }
    }

    // The decomposed narrative sections. Inline: each section is its own card
    // (the general route's main body). Collapsed: tucked into one expandable
    // "Full read" card so technical/fundamental results don't repeat the
    // interpretation chunks above the fold.
    @ViewBuilder
    private func narrativeSections(_ sections: [NarrativeSection], inline: Bool) -> some View {
        if !sections.isEmpty {
            if inline {
                ForEach(sections) { section in
                    Card(title: section.header) {
                        NarrativeSectionBody(section: section)
                    }
                }
            } else {
                expandableSection(
                    title: "Full read",
                    systemImage: "text.alignleft",
                    initiallyExpanded: false
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.header.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                NarrativeSectionBody(section: section)
                            }
                        }
                    }
                }
            }
        }
    }

    // "What this means" — short, labeled, number-free chunks (Momentum / Trend /
    // Range). Rendered only when the backend produced chunks (technical /
    // fundamental); for the general route the verdict line carries the summary,
    // so this stays empty rather than duplicating it.
    @ViewBuilder
    private func whatThisMeansSection(_ analysis: AnalysisData) -> some View {
        if !analysis.interpretation.isEmpty {
            Card(title: "What this means") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(analysis.interpretation, id: \.label) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(section.body)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // V11-01: "What this means for you" — the user's real position in the
    // analyzed ticker, resolved on-device. Its own card so the cloud analysis
    // above stays verbatim (additive).
    private func positionInsightSection(_ insight: PositionInsight) -> some View {
        Card(title: PositionInsight.title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(insight.lines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line).font(.subheadline)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(FinTheme.mint)
                    }
                }
                Text(insight.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // V11-03: portfolio-level overview — diversification, sector concentration,
    // and overall risk, computed on-device from the generalized profile. Leads
    // with a plain-language conclusion (Phase 10); findings follow as chips.
    private func portfolioAnalysisSection(_ analysis: PortfolioAnalysis) -> some View {
        Card(title: PortfolioAnalysis.title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(analysis.lead)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(analysis.findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.tag)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(FinTheme.mint.opacity(0.15))
                            .foregroundStyle(FinTheme.mint)
                            .clipShape(Capsule())
                        Text(finding.detail)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(analysis.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(analysis.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // P5-08: holdings-specific context resolved on-device. Rendered as its own
    // card so the cloud analysis above stays verbatim.
    private func personalizedContextSection(_ context: PersonalizedContext) -> some View {
        Card(title: PersonalizedContext.title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(context.lines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line).font(.subheadline)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(FinTheme.mint)
                    }
                }
                Text(context.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            let recent = Array(history.prefix(10))
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Recent")
                    .padding(.horizontal, 4)
                GlassPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                selectedHistoryEntry = entry
                            } label: {
                                HStack(spacing: 12) {
                                    Text(entry.ticker)
                                        .font(.system(size: 11.5, weight: .heavy))
                                        .tracking(0.3)
                                        .foregroundStyle(FinTheme.textPrimary)
                                        .padding(.horizontal, 6)
                                        .frame(minWidth: 42, minHeight: 30)
                                        .background(
                                            FinTheme.inset,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.query)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(FinTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(entry.createdAt, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(FinTheme.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(FinTheme.textTertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            if index < recent.count - 1 {
                                Rectangle().fill(FinTheme.line).frame(height: 1)
                            }
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
        queryFocused = false
        showSuggestions = false
        auditErrorMessage = nil
        localOnlyMessage = nil
        enrichedContext = nil
        positionInsight = nil
        portfolioAnalysis = nil
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
        // Holdings from *every* imported ledger. Used both by the V11-03
        // whole-portfolio overview below and the V11-02 cloud concentration
        // scoping further down, so "whole portfolio" spans all accounts.
        let allHoldings = ledgers.flatMap { $0.holdings }

        // V11-03: a whole-portfolio question is answered entirely on-device from
        // the *generalized* profile — diversification, sector concentration, and
        // overall risk — so no holdings or identity ever leave. Intercept it
        // before the cloud-routing path runs at all.
        //
        // Only when the ticker field is empty: a question that names a ticker
        // ("how does AAPL fit in my portfolio") wants the per-ticker pipeline,
        // not the generic overview — so a filled ticker takes precedence.
        if tickerSymbol.isEmpty && PortfolioAnalyzer.isPortfolioLevelQuery(rawQuery) {
            routingTask?.cancel()
            controller?.clear()
            submittedQuery = rawQuery
            // P1: build the generalized profile over holdings from *every*
            // imported ledger, so "whole portfolio" spans all accounts (Fidelity
            // + Vanguard + …) rather than just the newest import's profile.
            let held = allHoldings.filter { $0.quantity > 0 }
            guard !held.isEmpty else {
                portfolioAnalysis = nil
                localOnlyMessage = "Import a brokerage CSV in the Portfolio tab to get a portfolio "
                    + "overview. No cloud request was made."
                return
            }
            // The generalized profile is the query-scoped context for a
            // portfolio-level question (V9-03): sector categories + buckets, never
            // identity. The analysis is interpreted in plain language on-device.
            let combined = CSVPrivacyParser.makeShareableProfile(from: held, now: .now)
            let generalized = DifferentialPrivacy.generalize(
                profile: combined, privacyLevel: privacyLevel
            )
            portfolioAnalysis = PortfolioAnalyzer.analyze(generalized)
            if portfolioAnalysis == nil {
                localOnlyMessage = "Your imported portfolio has no sector data to summarize yet. "
                    + "No cloud request was made."
            }
            return
        }

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
            let rewritten = await rewriter.rewrite(
                query: rawQuery, ledger: ledger, privacyLevel: privacyLevel
            )
            if Task.isCancelled { return }

            // Hybrid is the only intent that earns generalized portfolio
            // context: a pure market question (.cloudAnalysis) ships without
            // a profile so we don't leak personal weights on an unrelated
            // query. When no ShareableProfile exists yet, the call still goes
            // out — without profile context — so the user isn't blocked on
            // having imported a CSV.
            // V9-03: scope the portfolio context to the question — a query about
            // a held ticker sends just that holding's specifics + minimal
            // context; a portfolio-level question sends sector weights.
            let generalized: GeneralizedProfile? = (intent == .hybrid && profile != nil)
                ? DifferentialPrivacy.scopedContext(
                    query: rawQuery, holdings: allHoldings, profile: profile!, privacyLevel: privacyLevel
                )
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
                analysisType: type,
                // V12-04: tell the backend whether this type was the user's
                // explicit pick (respected) or auto-detected (server may
                // re-derive from the query text).
                typeOverridden: analysisTypeUserOverridden
            )
            // Pin the submitted question to this result as the stream begins
            // (start() clears the prior finalResult), so the lead assessment is
            // framed against the question actually asked — not a later edit.
            submittedQuery = rawQuery
            submittedType = type
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
            riskOrientation: generalized.riskScore.map(riskOrientationLabel),
            focus: generalized.focus
        )
    }

    private static func riskOrientationLabel(_ score: Double) -> String {
        switch score {
        case ..<0.34: return "conservative"
        case ..<0.67: return "balanced"
        default: return "aggressive"
        }
    }

    // P5-08: map the generalized cloud narrative back to the user's specific
    // holdings, entirely on-device. Additive — the result populates a separate
    // section and never alters the cloud analysis text.
    private func recontextualize(_ response: AnalysisResponse?) {
        guard let response else {
            enrichedContext = nil
            positionInsight = nil
            return
        }
        // P2: recontextualize against holdings from *every* imported ledger, not
        // just the newest — a position held in an older/other account still counts.
        let holdings = ledgers.flatMap { $0.holdings }
        let recontextualizer = Recontextualizer(gemma: gemma)
        Task { @MainActor in
            let result = await recontextualizer.enrich(response: response, holdings: holdings)
            // Drop a stale enrichment if a newer result has since arrived.
            guard controller?.finalResult?.sessionId == response.sessionId else { return }
            enrichedContext = result.personalizedContext
            positionInsight = result.positionInsight
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

    // Confidence dot colors per the comp's AfConfidence: green for a solid
    // read, amber for a thin one, muted when there wasn't enough data.
    private func confidenceColor(_ value: String) -> Color {
        switch value.lowercased() {
        case "high", "moderate", "medium": return FinTheme.accent
        case "low": return FinTheme.amber
        default: return FinTheme.textTertiary
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
                    .tracking(0.9)
                    .foregroundStyle(FinTheme.textTertiary)
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

// MARK: - Section bodies

private struct TechnicalIndicatorsView: View {
    let indicators: [String: JSONValue]

    // V7-01: rendering lives in the shared IndicatorRowsView so every surface
    // unpacks nested MACD/Bollinger objects identically.
    var body: some View {
        IndicatorRowsView(indicators: indicators)
    }
}

// Placeholder rows for the report still streaming in (the comp's shimmer
// bars): inset-colored bars pulsing gently, widths tapering like prose.
private struct ShimmerLines: View {
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            bar(fraction: 0.92)
            bar(fraction: 0.78)
            bar(fraction: 0.55)
        }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    private func bar(fraction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FinTheme.inset)
            .frame(height: 11)
            .frame(maxWidth: .infinity)
            .scaleEffect(x: fraction, anchor: .leading)
            .opacity(pulsing ? 0.45 : 1)
    }
}

// One decomposed narrative section: bullets for discrete items (headlines,
// individual signal reads), short prose for context. Shared by the live result
// card and the persisted history detail.
private struct NarrativeSectionBody: View {
    let section: NarrativeSection

    var body: some View {
        if section.bullets.isEmpty {
            Text(section.prose)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(FinTheme.accent)
                        Text(item)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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

    @Environment(\.modelContext) private var modelContext
    // V12-03: paper trades placed from this analysis, resolved from the store so
    // the reverse link survives restarts.
    @State private var linkedTrades: [PaperTradeRecord] = []
    @State private var selectedTrade: PaperTradeRecord?

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
                        // Same chat-style decomposition as the live result:
                        // takeaway line, then sections — no paragraph wall.
                        // History entries keep only the prose, so headlines are
                        // recovered from the narrative's own marker sentence.
                        let presentation = AnalysisResultPresenter.presentation(
                            verdict: "", narrative: entry.narrative, query: entry.query
                        )
                        Text(presentation.takeaway)
                            .font(.body.weight(.semibold))
                        ForEach(presentation.sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.header)
                                    .font(.headline)
                                NarrativeSectionBody(section: section)
                            }
                        }
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
                    linkedTradesSection
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
            .onAppear {
                linkedTrades = AnalysisTradeLink.linkedTrades(forSessionID: entry.sessionID, in: modelContext)
            }
            .sheet(item: $selectedTrade) { trade in
                LinkedAnalysisSheet(trade: trade, modelContext: modelContext)
            }
        }
    }

    // V12-03 (AC2): an analysis that led to a trade links to that trade; tapping
    // it opens the trade (and, from there, back to this analysis).
    @ViewBuilder
    private var linkedTradesSection: some View {
        if !linkedTrades.isEmpty {
            Divider()
            Text("Paper trades from this analysis").font(.headline)
            LinkedTradesList(trades: linkedTrades) { selectedTrade = $0 }
        }
    }
}

// V12-03: shared list of trades linked to an analysis, used by both the live
// result card and the persisted history detail. Tapping a row opens the trade.
private struct LinkedTradesList: View {
    let trades: [PaperTradeRecord]
    let onTap: (PaperTradeRecord) -> Void

    var body: some View {
        ForEach(trades) { trade in
            Button { onTap(trade) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(trade.side.uppercased()) \(formatQty(trade.qty)) · \(trade.status)")
                            .font(.subheadline)
                        Text(trade.submittedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func formatQty(_ qty: Double) -> String {
        qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(qty))
            : String(format: "%.2f", qty)
    }
}
