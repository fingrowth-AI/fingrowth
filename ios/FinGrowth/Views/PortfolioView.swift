import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

// Portfolio tab (P4-04). Three sub-views via a segmented picker:
//   - Holdings: imported PrivateLedger rows + remote paper positions
//   - Orders:   paper trade history with link back to the source analysis
//   - Performance: cumulative paper-trade return vs SPY benchmark
//
// `PortfolioStore` owns remote fetches and local persistence of placed
// trades. This file is presentation only.

struct PortfolioView: View {
    let store: PortfolioStore
    let paperTradePrefill: PaperTradePrefill
    let gemma: GemmaService
    // Performance empty-state CTA: jump back to the Research tab.
    var onSwitchToResearch: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PrivateLedger.importedAt, order: .reverse)
    private var importedLedgers: [PrivateLedger]
    @Query(sort: \PaperTradeRecord.submittedAt, order: .reverse)
    private var paperTrades: [PaperTradeRecord]

    @State private var section: PortfolioSection = .holdings
    @State private var showOrderForm: Bool = false
    @State private var selectedTradeForAnalysis: PaperTradeRecord?
    @State private var showCSVImporter: Bool = false
    @State private var csvImportError: String?
    @State private var lastImportSummary: String?
    @Environment(\.colorScheme) private var colorScheme

    enum PortfolioSection: String, CaseIterable, Identifiable {
        case holdings, orders, performance
        var id: String { rawValue }
        var title: String {
            switch self {
            case .holdings: "Holdings"
            case .orders: "Orders"
            case .performance: "Performance"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MarketBackground()
                VStack(spacing: 12) {
                    portfolioHeader
                        .padding(.horizontal)
                        .padding(.top, 8)

                    Picker("Section", selection: $section) {
                        ForEach(PortfolioSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    Group {
                        switch section {
                        case .holdings:
                            HoldingsSection(
                                store: store,
                                importedLedgers: importedLedgers,
                                lastImportSummary: lastImportSummary,
                                onImportCSV: { showCSVImporter = true }
                            )
                        case .orders:
                            OrdersSection(
                                store: store,
                                paperTrades: paperTrades,
                                onTapAnalysis: { selectedTradeForAnalysis = $0 }
                            )
                        case .performance:
                            PerformanceSection(
                                store: store,
                                paperTrades: paperTrades,
                                onSwitchToResearch: onSwitchToResearch
                            )
                        }
                    }
                }
            }
            .navigationTitle("Portfolio")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showOrderForm = true } label: {
                        Label("New paper trade", systemImage: "plus.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isLoading)
                }
            }
            .task {
                if case .idle = store.loadState {
                    await store.refresh()
                }
            }
            .onChange(of: paperTradePrefill.pending) { _, pending in
                if pending != nil { showOrderForm = true }
            }
            .sheet(isPresented: $showOrderForm) {
                PaperTradeOrderSheet(
                    store: store,
                    paperTradePrefill: paperTradePrefill
                )
            }
            .sheet(item: $selectedTradeForAnalysis) { trade in
                LinkedAnalysisSheet(trade: trade, modelContext: modelContext)
            }
            .fileImporter(
                isPresented: $showCSVImporter,
                allowedContentTypes: csvImportContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleCSVImport(result: result)
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { csvImportError != nil },
                    set: { if !$0 { csvImportError = nil } }
                ),
                presenting: csvImportError
            ) { _ in
                Button("OK", role: .cancel) { csvImportError = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private var portfolioHeader: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(FinTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(FinTheme.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Portfolio")
                            .font(.title2.weight(.bold))
                        Text("Paper positions, private imports, and benchmark context.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    portfolioMetric("Positions", value: "\(store.positions.count)", color: FinTheme.accent)
                    portfolioMetric("Trades", value: "\(paperTrades.count)", color: FinTheme.mint)
                    if let value = totalMarketValue {
                        portfolioMetric("Value", value: formatPrice(value), color: FinTheme.amber)
                    }
                }
            }
        }
    }

    private var totalMarketValue: Double? {
        let values = store.positions.compactMap(\.marketValue)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    // CSV plus a couple of brokerage-export variants. UTType.commaSeparatedText
    // would already cover .csv on most brokers, but Schwab in particular
    // sometimes labels the file as text/plain.
    private var csvImportContentTypes: [UTType] {
        [.commaSeparatedText, .plainText, .text]
    }

    private func handleCSVImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accountName = url.deletingPathExtension().lastPathComponent
            Task { await importCSV(at: url, accountName: accountName) }
        case .failure(let error):
            // User cancellation surfaces here too; suppress to avoid noise.
            if (error as NSError).code != NSUserCancelledError {
                csvImportError = error.localizedDescription
            }
        }
    }

    // Gemma-powered import (P5-03): parses on-device, retains PII only in the
    // PrivateLedger, and reports how many PII fields were detected and kept off
    // the cloud.
    @MainActor
    private func importCSV(at url: URL, accountName: String) async {
        do {
            let text = try readCSV(at: url)
            let imported = try await CSVPrivacyParser.parse(
                csvData: text,
                accountName: accountName,
                gemma: gemma
            )
            modelContext.insert(imported.ledger)
            modelContext.insert(imported.profile)
            try modelContext.save()
            var summary = "Imported \(imported.ledger.holdings.count) holdings from \(imported.format.rawValue)."
            if imported.piiReport.containsPII {
                summary += " \(imported.piiReport.findings.count) PII field(s) kept on-device."
            }
            lastImportSummary = summary
        } catch let error as CSVParserError {
            csvImportError = error.errorDescription
        } catch {
            csvImportError = "Couldn't import CSV: \(error.localizedDescription)"
        }
    }

    private func readCSV(at url: URL) throws -> String {
        // Files vended through the document picker are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // Some brokerage exports are Latin-1 / Windows-1252.
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        throw CSVParserError.empty
    }
}

// MARK: - Holdings

private struct HoldingsSection: View {
    let store: PortfolioStore
    let importedLedgers: [PrivateLedger]
    let lastImportSummary: String?
    let onImportCSV: () -> Void

    var body: some View {
        List {
            Section("Paper positions") {
                if store.positions.isEmpty {
                    emptyRow(
                        title: "No paper positions",
                        subtitle: paperEmptyMessage
                    )
                } else {
                    ForEach(store.positions) { position in
                        PaperPositionRow(position: position)
                    }
                }
            }

            Section {
                if importedLedgers.isEmpty {
                    emptyRow(
                        title: "No imported ledger",
                        subtitle: "Import a Fidelity, Schwab, or Robinhood CSV. Parsed on-device; raw rows never leave your phone."
                    )
                } else {
                    ForEach(importedLedgers) { ledger in
                        LedgerRow(ledger: ledger)
                    }
                }
                Button {
                    onImportCSV()
                } label: {
                    Label("Import brokerage CSV", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Imported holdings")
            } footer: {
                if let lastImportSummary {
                    Text(lastImportSummary).font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .top) {
            if case .failed(let message) = store.loadState {
                LoadErrorBanner(message: message)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
    }

    private var paperEmptyMessage: String {
        switch store.loadState {
        case .failed: "Couldn't fetch positions — pull to retry above."
        case .loading: "Loading…"
        default: "Place a paper trade from the Research tab or the + button."
        }
    }

    private func emptyRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LedgerRow: View {
    let ledger: PrivateLedger

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ledger.accountName).font(.subheadline.weight(.semibold))
                if let brokerage = ledger.sourceBrokerage, !brokerage.isEmpty {
                    Text(brokerage)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                Text("Imported \(ledger.importedAt, style: .date)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if ledger.holdings.isEmpty {
                Text("No holdings parsed from this import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ledger.holdings.sorted(by: { $0.ticker < $1.ticker })) { holding in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(holding.ticker).font(.subheadline)
                            if let detail = holdingDetail(holding) {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(qtyString(holding.quantity)) @ \(formatPrice(holding.costBasis))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // Account type + acquisition date when the brokerage export shipped them
    // (design §8.1 Holding). Both are device-only PrivateLedger detail.
    private func holdingDetail(_ holding: LedgerHolding) -> String? {
        var parts: [String] = []
        if let accountType = holding.accountType, !accountType.isEmpty {
            parts.append(accountType)
        }
        if let purchaseDate = holding.purchaseDate {
            parts.append("acq. " + purchaseDate.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func qtyString(_ qty: Double) -> String {
        qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(qty))
            : String(format: "%.2f", qty)
    }
}

private struct PaperPositionRow: View {
    let position: BrokerPosition

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(position.symbol).font(.subheadline.weight(.semibold))
                Text("\(qtyString) \(position.side.uppercased()) @ \(formatPrice(position.avgEntryPrice))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let value = position.marketValue {
                    Text(formatPrice(value)).font(.subheadline.monospacedDigit())
                }
                if let pl = position.unrealizedPl {
                    Text(plLabel(pl))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(pl >= 0 ? .green : .red)
                }
            }
        }
    }

    private var qtyString: String {
        position.qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(position.qty))
            : String(format: "%.2f", position.qty)
    }
}

// MARK: - Orders

private struct OrdersSection: View {
    let store: PortfolioStore
    let paperTrades: [PaperTradeRecord]
    let onTapAnalysis: (PaperTradeRecord) -> Void

    var body: some View {
        // V12-02: deterministic thesis outcomes from realized round trips, and
        // the running hit-rate across them.
        let outcomes = ThesisOutcomeEngine.outcomesByOpeningOrderID(from: paperTrades)
        let hitRate = ThesisOutcomeEngine.hitRate(ThesisOutcomeEngine.closedTheses(from: paperTrades))

        return List {
            if paperTrades.isEmpty && store.orders.isEmpty {
                Section {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !paperTrades.isEmpty {
                Section("Placed in app") {
                    // Always shown once any trade exists; reads "No closed theses
                    // yet" until a round trip completes (V12-02).
                    ThesisHitRateRow(hitRate: hitRate)
                    ForEach(paperTrades) { trade in
                        Button { onTapAnalysis(trade) } label: {
                            PaperTradeRow(trade: trade, outcome: outcomes[trade.brokerOrderID])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !store.orders.isEmpty {
                Section("Broker history") {
                    ForEach(store.orders) { order in
                        BrokerOrderRow(order: order)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyMessage: String {
        switch store.loadState {
        case .failed(let message): message
        case .loading: "Loading orders…"
        default: "No paper trades yet. Place one from Research → \"Test with paper trade\"."
        }
    }
}

private struct PaperTradeRow: View {
    let trade: PaperTradeRecord
    // V12-02: set when this trade's thesis has been closed out as a round trip.
    var outcome: ThesisOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trade.ticker).font(.subheadline.weight(.semibold))
                if let outcome {
                    ThesisOutcomeBadge(outcome: outcome)
                }
                Spacer()
                Text(trade.submittedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("\(trade.side.uppercased()) \(qtyString) · \(trade.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if trade.sourceResearchSessionID != nil || !trade.sourceQuery.isEmpty {
                    Label("Linked analysis", systemImage: "link.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var qtyString: String {
        trade.qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(trade.qty))
            : String(format: "%.2f", trade.qty)
    }
}

// V12-02: a deterministic confirmed / not-confirmed chip for a closed thesis.
private struct ThesisOutcomeBadge: View {
    let outcome: ThesisOutcome

    var body: some View {
        let confirmed = outcome == .confirmed
        Label(outcome.label, systemImage: confirmed ? "checkmark.seal.fill" : "xmark.seal")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((confirmed ? FinTheme.accent : FinTheme.danger).opacity(0.15))
            .foregroundStyle(confirmed ? FinTheme.accent : FinTheme.danger)
            .clipShape(Capsule())
    }
}

// V12-02: running hit-rate across the user's closed theses.
private struct ThesisHitRateRow: View {
    let hitRate: ThesisHitRate

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Thesis hit-rate")
                    .font(.caption.weight(.semibold))
                Text(hitRate.display)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BrokerOrderRow: View {
    let order: BrokerOrder

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.symbol).font(.subheadline.weight(.semibold))
                Text("\(order.side.uppercased()) \(qtyString) · \(order.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let submitted = order.submittedAt {
                Text(submitted, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qtyString: String {
        order.qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(order.qty))
            : String(format: "%.2f", order.qty)
    }
}

// MARK: - Performance

private struct PerformanceSection: View {
    let store: PortfolioStore
    let paperTrades: [PaperTradeRecord]
    var onSwitchToResearch: () -> Void = {}

    @State private var selectedDate: Date?
    @State private var range: PerfRange = .m1

    // Window selector under the chart (screens-after-perf). Each case maps to
    // the day count handed to the backend performance endpoint.
    private enum PerfRange: String, CaseIterable, Identifiable {
        case w1 = "1W"
        case m1 = "1M"
        case m3 = "3M"
        case ytd = "YTD"
        case all = "All"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .w1: return 7
            case .m1: return 30
            case .m3: return 90
            case .ytd:
                let calendar = Calendar.current
                guard let start = calendar.date(
                    from: calendar.dateComponents([.year], from: .now)
                ) else { return 30 }
                let elapsed = calendar.dateComponents([.day], from: start, to: .now).day ?? 30
                return max(7, elapsed)
            case .all: return 365
            }
        }

        // Hero subtitle when not scrubbing ("+$12.34 (+1.2%) Past month").
        var title: String {
            switch self {
            case .w1: return "Past week"
            case .m1: return "Past month"
            case .m3: return "Past 3 months"
            case .ytd: return "Year to date"
            case .all: return "Past year"
            }
        }
    }

    // SPY line color from the comp (#6E7A73) — between the t2/t3 text tiers.
    private static let benchmarkTint = Color(
        red: 0x6E / 255.0, green: 0x7A / 255.0, blue: 0x73 / 255.0
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let chart = chartData, hasTradeActivity(chart) {
                    performanceHero(chart)
                        .padding(.horizontal, 4)
                    chartCard(chart)
                    supportTiles(chart)
                } else {
                    emptyHero
                        .padding(.horizontal, 4)
                    emptyStateCard
                    emptyStateCTA
                }

                if !allocationData.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Open position mix")
                            .padding(.horizontal, 4)
                        GlassPanel {
                            VStack(spacing: 12) {
                                allocationChart
                                    .frame(height: allocationChartHeight)
                                allocationRows
                            }
                        }
                    }
                }

                if !positionPLData.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Unrealized P/L")
                            .padding(.horizontal, 4)
                        GlassPanel {
                            positionPLChart
                                .frame(height: positionPLChartHeight)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Stats")
                        .padding(.horizontal, 4)
                    GlassPanel {
                        VStack(spacing: 10) {
                            statRow(label: "Paper trades placed", value: "\(paperTrades.count)")
                            statRow(label: "Open positions", value: "\(store.positions.count)")
                            if let totalValue = totalMarketValue {
                                statRow(label: "Total market value", value: formatPrice(totalValue))
                            }
                            if let totalPL = totalUnrealized {
                                statRow(
                                    label: "Unrealized P/L",
                                    value: plLabel(totalPL),
                                    valueColor: totalPL >= 0 ? FinTheme.accent : FinTheme.danger
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        // The curve is best-effort on the shared refresh; if it was missing
        // (e.g. a rate-limited benchmark), retry when the user actually opens
        // the Performance section instead of waiting for a manual refresh.
        .task {
            if store.performance == nil, !store.isLoading {
                await store.refresh()
            }
        }
    }

    // Dollar mode with no trades is a dead-flat $0 line that reads as a broken
    // chart; the guided empty state (with its "place your first paper trade"
    // CTA) is the honest render for that. The percent fallback keeps the old
    // behavior, where the SPY overlay gives the window shape even with no
    // trades.
    private func hasTradeActivity(_ series: PerformanceSeries) -> Bool {
        guard series.hasInvestedData else { return true }
        return series.portfolio.contains {
            abs($0.invested ?? 0) > 0.005 || abs($0.pnl ?? 0) > 0.005
        }
    }

    private struct PerformanceSeries {
        var portfolio: [ReturnPoint]
        var benchmark: [ReturnPoint]

        // Dollar mode: available once the backend ships the trade-sized
        // invested/pnl fields. The hero and chart then show what the user's
        // trades are worth (and their P/L), not deltas on the $100K seed.
        var hasInvestedData: Bool {
            portfolio.contains { $0.invested != nil }
        }

        // Window baselines for the dollar mode.
        var baseInvested: Double { portfolio.first?.invested ?? 0 }
        var basePnl: Double { portfolio.first?.pnl ?? 0 }
    }

    private struct ReturnPoint: Hashable {
        var date: Date
        var returnPct: Double
        var equity: Double?
        var invested: Double?
        var pnl: Double?
    }

    private struct Snapshot {
        var date: Date
        var portfolioReturn: Double
        var benchmarkReturn: Double?
        var equity: Double?
        var invested: Double?
        var pnl: Double?
    }

    private struct PositionAllocation: Identifiable {
        var symbol: String
        var value: Double
        var weight: Double
        var id: String { symbol }
    }

    private struct PositionPL: Identifiable {
        var symbol: String
        var value: Double
        var id: String { symbol }
    }

    // Hero block, Robinhood-style: the market value of the user's paper
    // trades as the one big number (in the primary text color), with the
    // window's P/L — signed dollars and percent — colored by direction
    // underneath, then the SPY comparison row. Deliberately trade-sized: $100
    // of stock that's down $10 reads "$90.00, -$10.00", not a hairline move on
    // the $100K virtual seed (the seed still caps buying power, it just isn't
    // displayed as if it were money at work). Scrubbing the chart re-points
    // the whole block at the selected day. Falls back to the percent-first
    // layout when the backend doesn't ship the invested/pnl fields.
    @ViewBuilder
    private func performanceHero(_ series: PerformanceSeries) -> some View {
        let snapshot = selectedSnapshot(in: series)
        let portfolioReturn = snapshot?.portfolioReturn ?? latestPortfolioReturn(in: series)
        let benchmarkReturn = snapshot?.benchmarkReturn ?? latestBenchmarkReturn(in: series)
        VStack(alignment: .leading, spacing: 4) {
            if series.hasInvestedData {
                let invested = snapshot?.invested ?? latestInvested(in: series) ?? 0
                let pnlDelta = windowPnlDelta(in: series, snapshot: snapshot)
                SectionLabel("Your trades · paper")
                Text(formatPrice(invested))
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(FinTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: invested)
                HStack(spacing: 8) {
                    Text(pnlChangeLabel(pnlDelta, invested: invested))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(returnColor(pnlDelta))
                    Text(heroDateLabel(series, snapshot: snapshot))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FinTheme.textSecondary)
                }
            } else {
                SectionLabel("Cumulative return · paper")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(percentLabel(portfolioReturn))
                        .font(.system(size: 40, weight: .heavy))
                        .tracking(-1)
                        .monospacedDigit()
                        .foregroundStyle(returnColor(portfolioReturn))
                    Text(heroDateLabel(series, snapshot: snapshot))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FinTheme.textSecondary)
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.benchmarkTint)
                    .frame(width: 8, height: 8)
                Text("SPY \(percentLabel(benchmarkReturn)) over this window")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(FinTheme.textSecondary)
        }
    }

    // The window name ("Past month") when at rest, or the scrubbed day's date.
    private func heroDateLabel(_ series: PerformanceSeries, snapshot: Snapshot?) -> String {
        if selectedDate != nil, let snapshot {
            return snapshot.date.formatted(.dateTime.month(.abbreviated).day())
        }
        return range.title
    }

    private func latestInvested(in series: PerformanceSeries) -> Double? {
        series.portfolio.last(where: { $0.invested != nil })?.invested
    }

    // P/L movement from the window's first day to the shown day.
    private func windowPnlDelta(in series: PerformanceSeries, snapshot: Snapshot?) -> Double {
        let shown = snapshot?.pnl
            ?? series.portfolio.last(where: { $0.pnl != nil })?.pnl
            ?? 0
        return shown - series.basePnl
    }

    // "+$12.34 (+1.2%)" — percent relative to the money that was at work
    // (invested value minus the window's move backs out to roughly the cost
    // basis). Dollars only when nothing is currently invested, where a percent
    // has no meaningful base.
    private func pnlChangeLabel(_ pnlDelta: Double, invested: Double) -> String {
        let basis = invested - pnlDelta
        guard invested > 0.005, basis > 0.005 else { return plLabel(pnlDelta) }
        let pct = pnlDelta / basis * 100
        return "\(plLabel(pnlDelta)) (\(percentLabel(pct)))"
    }

    private func chartCard(_ series: PerformanceSeries) -> some View {
        GlassPanel {
            VStack(spacing: 10) {
                performanceChart(series)
                    .frame(height: 220)
                Rectangle()
                    .fill(FinTheme.line)
                    .frame(height: 1)
                    .padding(.horizontal, -16)
                rangeChips
            }
        }
    }

    // Robinhood-style chart: no axes or gridlines, a straight (linear) line
    // colored by the window's direction — green when up from the window start,
    // red when down — over a soft matching gradient, with a dashed line at the
    // window's starting value. In dollar mode the curve is the market value of
    // the user's trades (so a $100 buy that slips $10 visibly falls 100 → 90);
    // SPY stays out of that view because percent and dollars don't share an
    // axis — it remains in the hero row and in the percent fallback chart.
    // Scrubbing pins a vertical hairline with the day's date above it and
    // ticks a selection haptic per data point.
    @ViewBuilder
    private func performanceChart(_ series: PerformanceSeries) -> some View {
        let dollarMode = series.hasInvestedData
        let snapshot = selectedSnapshot(in: series)
        let tint = dollarMode
            ? returnColor(windowPnlDelta(in: series, snapshot: snapshot))
            : returnColor(snapshot?.portfolioReturn ?? latestPortfolioReturn(in: series))
        let baseline = dollarMode ? series.baseInvested : 0
        Chart {
            ForEach(series.portfolio, id: \.self) { point in
                let y = dollarMode ? (point.invested ?? 0) : point.returnPct
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Baseline", baseline),
                    yEnd: .value("Value", y)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.16), tint.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Value", y),
                    series: .value("Series", "Portfolio")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            if !dollarMode {
                ForEach(series.benchmark, id: \.self) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Return", point.returnPct),
                        series: .value("Series", "SPY")
                    )
                    .foregroundStyle(Self.benchmarkTint.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }

            // The window's starting value.
            RuleMark(y: .value("Start", baseline))
                .foregroundStyle(FinTheme.textTertiary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))

            if selectedDate != nil, let snapshot {
                let selectedY = dollarMode
                    ? (snapshot.invested ?? 0)
                    : snapshot.portfolioReturn
                RuleMark(x: .value("Selected date", snapshot.date))
                    .foregroundStyle(FinTheme.textTertiary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        Text(snapshot.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FinTheme.textSecondary)
                    }

                PointMark(
                    x: .value("Selected date", snapshot.date),
                    y: .value("Value", selectedY)
                )
                .foregroundStyle(tint)
                .symbolSize(60)

                if !dollarMode, let benchmarkReturn = snapshot.benchmarkReturn {
                    PointMark(
                        x: .value("Selected date", snapshot.date),
                        y: .value("SPY return", benchmarkReturn)
                    )
                    .foregroundStyle(Self.benchmarkTint)
                    .symbolSize(36)
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        // One tick per data point while the finger sweeps across days.
        .sensoryFeedback(.selection, trigger: snapshot?.date)
    }

    // 1W/1M/3M/YTD/All chips — the selected window re-fetches the per-user
    // performance series for that many days.
    private var rangeChips: some View {
        HStack(spacing: 6) {
            ForEach(PerfRange.allCases) { item in
                let isSelected = range == item
                Button {
                    guard range != item else { return }
                    range = item
                    selectedDate = nil
                    Task { await store.refresh(benchmarkDays: item.days) }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12.5, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? FinTheme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .foregroundStyle(isSelected ? FinTheme.onAccent : FinTheme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Best/worst single day and the thesis hit-rate as a row of small tiles.
    // In dollar mode the extremes are the biggest daily P/L swings in dollars,
    // matching the trade-sized hero; the percent fallback keeps return deltas.
    @ViewBuilder
    private func supportTiles(_ series: PerformanceSeries) -> some View {
        let dollarMode = series.hasInvestedData
        let extremes = bestWorstDay(series)
        let hitRate = ThesisOutcomeEngine.hitRate(ThesisOutcomeEngine.closedTheses(from: paperTrades))
        HStack(spacing: 8) {
            supportTile(
                "Best day",
                value: extremes.map { dollarMode ? plLabel($0.best) : percentLabel($0.best) } ?? "—",
                color: FinTheme.accent
            )
            supportTile(
                "Worst day",
                value: extremes.map { dollarMode ? plLabel($0.worst) : percentLabel($0.worst) } ?? "—",
                color: FinTheme.danger
            )
            supportTile(
                "Thesis hit-rate",
                value: hitRate.total > 0 ? "\(hitRate.confirmed) of \(hitRate.total)" : "—",
                color: FinTheme.textPrimary
            )
        }
    }

    private func supportTile(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FinTheme.textTertiary)
            Text(value)
                .font(.system(size: 16.5, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(FinTheme.card)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(FinTheme.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // Day-over-day move extremes along the curve — P/L dollars in dollar
    // mode (buys/sells don't register as moves), return points otherwise.
    private func bestWorstDay(_ series: PerformanceSeries) -> (best: Double, worst: Double)? {
        let points = series.portfolio
        guard points.count >= 2 else { return nil }
        let dollarMode = series.hasInvestedData
        var deltas: [Double] = []
        for index in 1..<points.count {
            if dollarMode {
                deltas.append((points[index].pnl ?? 0) - (points[index - 1].pnl ?? 0))
            } else {
                deltas.append(points[index].returnPct - points[index - 1].returnPct)
            }
        }
        guard let best = deltas.max(), let worst = deltas.min() else { return nil }
        return (best, worst)
    }

    // MARK: - Empty state (screens-after-perf)

    private var loadFailureMessage: String? {
        if case .failed(let message) = store.loadState { return message }
        return nil
    }

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Your trades · paper")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("$0.00")
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(FinTheme.textTertiary)
                Text("no trades yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FinTheme.textTertiary)
            }
        }
    }

    // Ghost curve with the "Your curve starts here" overlay; surfaces the load
    // error in place of the invitation copy when the fetch actually failed.
    private var emptyStateCard: some View {
        GlassPanel {
            ZStack {
                GhostCurve()
                    .stroke(
                        FinTheme.accent.opacity(0.18),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 7])
                    )
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FinTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(FinTheme.accentDim, in: Circle())
                    Text(loadFailureMessage == nil ? "Your curve starts here" : "Performance is unavailable")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(FinTheme.textPrimary)
                    Text(loadFailureMessage
                        ?? "Place your first paper trade from any research result and we'll track it against SPY.")
                        .font(.footnote)
                        .foregroundStyle(FinTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyStateCTA: some View {
        Button(action: onSwitchToResearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Run a research query")
            }
            .font(.system(size: 15.5, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FinTheme.accentDim, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(FinTheme.accent.opacity(0.3), lineWidth: 1)
        }
        .foregroundStyle(FinTheme.accent)
    }

    private var allocationChart: some View {
        Chart(allocationData) { item in
            BarMark(
                x: .value("Market value", item.value),
                y: .value("Symbol", item.symbol)
            )
            .foregroundStyle(FinTheme.accent)
            .annotation(position: .trailing) {
                Text(weightLabel(item.weight))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(position: .bottom) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(shortCurrency(number))
                    }
                }
            }
        }
    }

    private var allocationRows: some View {
        VStack(spacing: 8) {
            ForEach(allocationData) { item in
                HStack {
                    Text(item.symbol)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(formatPrice(item.value))
                        .font(.caption.monospacedDigit())
                    Text(weightLabel(item.weight))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }

    private var positionPLChart: some View {
        Chart(positionPLData) { item in
            BarMark(
                x: .value("Unrealized P/L", item.value),
                y: .value("Symbol", item.symbol)
            )
            .foregroundStyle(item.value >= 0 ? FinTheme.accent : FinTheme.danger)
            .annotation(position: item.value >= 0 ? .trailing : .leading) {
                Text(plLabel(item.value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(item.value >= 0 ? FinTheme.accent : FinTheme.danger)
            }
        }
        .chartXAxis {
            AxisMarks(position: .bottom) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(shortCurrency(number))
                    }
                }
            }
        }
    }

    // V8-04: the chart binds to the backend's per-user performance series —
    // equity reconstructed from the user's own trade log (realized P/L carried
    // forward, so closed trades never drop off the curve) sampled on the
    // benchmark's trading days. Both returns arrive pre-baselined to the
    // window's first day, so the portfolio and SPY lines share one axis.
    private var chartData: PerformanceSeries? {
        guard let performance = store.performance, !performance.points.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        var portfolio: [ReturnPoint] = []
        var benchmark: [ReturnPoint] = []
        for point in performance.points {
            guard let date = formatter.date(from: point.date) else { continue }
            portfolio.append(ReturnPoint(
                date: date,
                returnPct: point.portfolioReturn * 100,
                equity: point.equity,
                invested: point.invested,
                pnl: point.pnl
            ))
            benchmark.append(ReturnPoint(
                date: date,
                returnPct: point.benchmarkReturn * 100,
                equity: nil
            ))
        }
        guard !portfolio.isEmpty else { return nil }
        return PerformanceSeries(portfolio: portfolio, benchmark: benchmark)
    }

    private var allocationData: [PositionAllocation] {
        let valued = store.positions.compactMap { position -> (symbol: String, value: Double)? in
            guard let value = position.marketValue, value > 0 else { return nil }
            return (position.symbol, value)
        }
        let total = valued.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        return valued
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map {
                PositionAllocation(
                    symbol: $0.symbol,
                    value: $0.value,
                    weight: ($0.value / total) * 100
                )
            }
    }

    private var positionPLData: [PositionPL] {
        store.positions
            .compactMap { position -> PositionPL? in
                guard let value = position.unrealizedPl else { return nil }
                return PositionPL(symbol: position.symbol, value: value)
            }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(8)
            .map { $0 }
    }

    private var allocationChartHeight: CGFloat {
        CGFloat(max(180, allocationData.count * 34))
    }

    private var positionPLChartHeight: CGFloat {
        CGFloat(max(180, positionPLData.count * 34))
    }

    private var totalMarketValue: Double? {
        let values = store.positions.compactMap(\.marketValue)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private var totalUnrealized: Double? {
        let values = store.positions.compactMap(\.unrealizedPl)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private func selectedSnapshot(in series: PerformanceSeries) -> Snapshot? {
        let targetDate = selectedDate ?? series.portfolio.last?.date
        guard let targetDate,
              let portfolioPoint = nearestPoint(to: targetDate, in: series.portfolio)
        else {
            return nil
        }
        let benchmarkPoint = nearestPoint(to: portfolioPoint.date, in: series.benchmark)
        return Snapshot(
            date: portfolioPoint.date,
            portfolioReturn: portfolioPoint.returnPct,
            benchmarkReturn: benchmarkPoint?.returnPct,
            equity: portfolioPoint.equity,
            invested: portfolioPoint.invested,
            pnl: portfolioPoint.pnl
        )
    }

    private func latestPortfolioReturn(in series: PerformanceSeries) -> Double? {
        series.portfolio.last?.returnPct
    }

    private func latestBenchmarkReturn(in series: PerformanceSeries) -> Double? {
        series.benchmark.last?.returnPct
    }

    private func nearestPoint(to date: Date, in points: [ReturnPoint]) -> ReturnPoint? {
        points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func statRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(valueColor ?? .primary)
        }
    }

    private func percentLabel(_ value: Double?) -> String {
        guard let value else { return "--" }
        let sign = value > 0 ? "+" : ""
        return sign + String(format: "%.2f%%", value)
    }

    private func weightLabel(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func returnColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value > 0 { return FinTheme.accent }
        if value < 0 { return FinTheme.danger }
        return .secondary
    }

    private func shortCurrency(_ value: Double) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""
        if absValue >= 1_000_000 {
            return sign + String(format: "$%.1fM", absValue / 1_000_000)
        }
        if absValue >= 1_000 {
            return sign + String(format: "$%.1fK", absValue / 1_000)
        }
        return sign + String(format: "$%.0f", absValue)
    }
}

// The empty Performance chart's dashed "future curve", scaled from the comp's
// 329×190 SVG path (screens-after-perf.jsx).
private struct GhostCurve: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 329
        let sy = rect.height / 190
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        path.move(to: point(0, 95))
        path.addCurve(to: point(100, 78), control1: point(40, 95), control2: point(60, 70))
        path.addCurve(to: point(230, 52), control1: point(150, 88), control2: point(180, 40))
        path.addCurve(to: point(329, 36), control1: point(270, 60), control2: point(300, 30))
        return path
    }
}

// MARK: - Order sheet

private struct PaperTradeOrderSheet: View {
    let store: PortfolioStore
    let paperTradePrefill: PaperTradePrefill
    @Environment(\.dismiss) private var dismiss

    @State private var ticker: String = ""
    @State private var side: Side?
    @State private var quantity: String = "1"
    @State private var thesis: String = ""
    @State private var sourceNote: String = ""
    @State private var pendingSource: PaperTradePrefill.Pending?
    @State private var isSubmitting: Bool = false

    enum Side: String, CaseIterable, Identifiable {
        case buy, sell
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ticker", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Side", selection: $side) {
                        Text("Select").tag(Side?.none)
                        ForEach(Side.allCases) { value in
                            Text(value.rawValue.capitalized).tag(Side?.some(value))
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Quantity", text: $quantity)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Paper trade")
                } footer: {
                    Text("Routes through the backend's Alpaca paper endpoint. Never live.")
                }

                // V12-01: a short thesis is required before the order can be
                // placed — the user states *why*, so the trade can later be
                // checked against its outcome. Stays on-device with the trade.
                Section {
                    TextField(
                        "Why are you placing this trade?",
                        text: $thesis,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                } header: {
                    Text("Thesis")
                } footer: {
                    Text("Required. Your own rationale — not advice. Stored privately on-device "
                        + "with this trade and its linked analysis.")
                }

                if !sourceNote.isEmpty {
                    Section("From research") {
                        Text(sourceNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = store.submitError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            HStack { ProgressView(); Text("Submitting…") }
                        } else {
                            Label("Submit paper trade", systemImage: "paperplane.fill")
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .navigationTitle("New paper trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                // Tap-to-dismiss can't be attached to a Form (the gesture
                // steals row buttons' taps — it broke Submit); a Done button
                // over the keyboard is the reliable Form-safe equivalent.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.dismissKeyboard() }
                }
            }
            .onAppear(perform: applyPrefill)
        }
    }

    private var canSubmit: Bool {
        PaperOrderForm.canPlace(
            ticker: ticker,
            sideSelected: side != nil,
            quantity: Double(quantity),
            thesis: thesis
        )
    }

    private func applyPrefill() {
        guard let pending = paperTradePrefill.consume() else { return }
        ticker = pending.ticker
        sourceNote = "\"\(pending.sourceQuery)\" · "
            + pending.sourceAnalysisType.rawValue.capitalized
            + " · confidence: \(pending.sourceConfidence)"
        pendingSource = pending
    }

    private func submit() async {
        guard let side, let qty = Double(quantity), qty > 0 else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let order = await store.placeOrder(
            ticker: ticker,
            qty: qty,
            side: side.rawValue,
            thesis: thesis,
            source: pendingSource
        )
        if order != nil {
            dismiss()
        }
    }
}

// MARK: - Linked analysis sheet

// Internal (not private) so the Research tab can present it for the reverse
// link (V12-03): from an analysis, open the trade it inspired.
struct LinkedAnalysisSheet: View {
    let trade: PaperTradeRecord
    let modelContext: ModelContext

    @State private var linkedEntry: ResearchHistoryEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    Divider()
                    if let entry = linkedEntry {
                        linkedAnalysis(entry: entry)
                    } else if !trade.sourceQuery.isEmpty {
                        cachedAnalysis
                    } else {
                        Text("This paper trade was placed without a linked analysis.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("\(trade.side.uppercased()) \(trade.ticker)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: resolveEntry)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(formatQty(trade.qty)) shares · \(trade.status)")
                .font(.subheadline.weight(.semibold))
            Text("Submitted \(trade.submittedAt, style: .date)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // V12-01: the rationale captured when the trade was placed.
            if !trade.thesis.isEmpty {
                Text("Your thesis: \(trade.thesis)")
                    .font(.footnote)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func linkedAnalysis(entry: ResearchHistoryEntry) -> some View {
        Text("Linked analysis").font(.headline)
        Text(entry.query).font(.body)
        Text("Confidence: \(entry.confidence)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if !entry.narrative.isEmpty {
            Text(entry.narrative).font(.body)
        }
        if !entry.indicators.isEmpty {
            Divider()
            Text("Technical indicators").font(.headline)
            // V7-01: shared renderer unpacks nested MACD/Bollinger objects so
            // a linked analysis never shows a raw "{…}" placeholder.
            IndicatorRowsView(indicators: entry.indicators)
        }
        Text(entry.disclaimer)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var cachedAnalysis: some View {
        Text("Linked analysis (snapshot)").font(.headline)
        Text(trade.sourceQuery).font(.body)
        Text("Type: \(trade.sourceAnalysisType.rawValue.capitalized) · confidence: \(trade.sourceConfidence)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text("The original analysis history entry is no longer available; the snapshot above was captured at trade time.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func resolveEntry() {
        linkedEntry = AnalysisTradeLink.linkedEntry(for: trade, in: modelContext)
    }

    private func formatQty(_ qty: Double) -> String {
        qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(qty))
            : String(format: "%.2f", qty)
    }
}

// MARK: - Shared helpers

private struct LoadErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private func portfolioMetric(_ title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        Text(value)
            .font(.subheadline.monospacedDigit().weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
}

private func formatPrice(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

private func plLabel(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : "−"
    return sign + String(format: "$%.2f", abs(value))
}
