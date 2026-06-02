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
                                paperTrades: paperTrades
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

    @State private var selectedDate: Date?
    @State private var focus: PerformanceFocus = .portfolio

    private enum PerformanceFocus: String, CaseIterable, Identifiable {
        case portfolio = "Portfolio"
        case benchmark = "SPY"
        case spread = "Spread"

        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                if let chart = chartData {
                    VStack(alignment: .leading, spacing: 16) {
                        performanceHeader(chart)

                        Picker("Focus", selection: $focus) {
                            ForEach(PerformanceFocus.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        performanceChart(chart)
                            .frame(height: 260)

                        chartLegend
                    }
                    .padding(.vertical, 4)
                } else {
                    Text(emptyChartMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Cumulative return")
            }

            if !allocationData.isEmpty {
                Section {
                    allocationChart
                        .frame(height: allocationChartHeight)
                    allocationRows
                } header: {
                    Text("Open position mix")
                }
            }

            if !positionPLData.isEmpty {
                Section {
                    positionPLChart
                        .frame(height: positionPLChartHeight)
                } header: {
                    Text("Unrealized P/L")
                }
            }

            Section("Stats") {
                statRow(label: "Paper trades placed", value: "\(paperTrades.count)")
                statRow(
                    label: "Open positions",
                    value: "\(store.positions.count)"
                )
                if let totalValue = totalMarketValue {
                    statRow(label: "Total market value", value: formatPrice(totalValue))
                }
                if let totalPL = totalUnrealized {
                    statRow(
                        label: "Unrealized P/L",
                        value: plLabel(totalPL),
                        valueColor: totalPL >= 0 ? .green : .red
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private struct PerformanceSeries {
        var portfolio: [ReturnPoint]
        var benchmark: [ReturnPoint]
    }

    private struct ReturnPoint: Hashable {
        var date: Date
        var returnPct: Double
        var equity: Double?
    }

    private struct Snapshot {
        var date: Date
        var portfolioReturn: Double
        var benchmarkReturn: Double?

        var spread: Double? {
            guard let benchmarkReturn else { return nil }
            return portfolioReturn - benchmarkReturn
        }
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

    @ViewBuilder
    private func performanceHeader(_ series: PerformanceSeries) -> some View {
        let snapshot = selectedSnapshot(in: series)
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot {
                Text(snapshot.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                metricTile(
                    "Portfolio",
                    value: percentLabel(snapshot?.portfolioReturn ?? latestPortfolioReturn(in: series)),
                    color: returnColor(snapshot?.portfolioReturn ?? latestPortfolioReturn(in: series))
                )
                metricTile(
                    "SPY",
                    value: percentLabel(snapshot?.benchmarkReturn ?? latestBenchmarkReturn(in: series)),
                    color: returnColor(snapshot?.benchmarkReturn ?? latestBenchmarkReturn(in: series))
                )
                metricTile(
                    "Spread",
                    value: percentLabel(snapshot?.spread ?? latestSpread(in: series)),
                    color: returnColor(snapshot?.spread ?? latestSpread(in: series))
                )
            }
        }
    }

    @ViewBuilder
    private func performanceChart(_ series: PerformanceSeries) -> some View {
        Chart {
            if focus != .benchmark {
                ForEach(series.portfolio, id: \.self) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Return", point.returnPct)
                    )
                    .foregroundStyle(FinTheme.accent.opacity(focus == .portfolio ? 0.18 : 0.08))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Return", point.returnPct),
                        series: .value("Series", "Portfolio")
                    )
                    .foregroundStyle(FinTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: focus == .portfolio ? 3 : 2))
                    .interpolationMethod(.catmullRom)
                }
            }

            if focus != .portfolio {
                ForEach(series.benchmark, id: \.self) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Return", point.returnPct),
                        series: .value("Series", "SPY")
                    )
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: focus == .benchmark ? 3 : 2, dash: [5, 4]))
                    .interpolationMethod(.catmullRom)
                }
            }

            if focus == .spread {
                ForEach(spreadPoints(in: series), id: \.self) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Spread", point.returnPct),
                        series: .value("Series", "Spread")
                    )
                    .foregroundStyle(FinTheme.amber)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.catmullRom)
                }
            }

            RuleMark(y: .value("Break even", 0))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            if let snapshot = selectedSnapshot(in: series) {
                RuleMark(x: .value("Selected date", snapshot.date))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("Selected date", snapshot.date),
                    y: .value("Portfolio return", snapshot.portfolioReturn)
                )
                .foregroundStyle(FinTheme.accent)
                .symbolSize(48)

                if let benchmarkReturn = snapshot.benchmarkReturn, focus != .portfolio {
                    PointMark(
                        x: .value("Selected date", snapshot.date),
                        y: .value("SPY return", benchmarkReturn)
                    )
                    .foregroundStyle(.secondary)
                    .symbolSize(42)
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pct = value.as(Double.self) {
                        Text(percentLabel(pct))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            legendItem("Portfolio", color: FinTheme.accent)
            legendItem("SPY", color: .secondary)
            if focus == .spread {
                legendItem("Spread", color: FinTheme.amber)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
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

    // Builds the chart from Alpaca's server-backed portfolio history: each
    // point is account *equity*, which already folds in realized P/L from
    // closed positions, so a completed trade never drops off the curve. Equity
    // is expressed as a cumulative return against the window's base value. The
    // SPY line is normalized to its close on/after the portfolio's first date
    // so both series start at 0% on the same baseline.
    private var chartData: PerformanceSeries? {
        guard let history = store.portfolioHistory, !history.points.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        let datedEquity: [(date: Date, equity: Double)] = history.points.compactMap { p in
            guard let date = formatter.date(from: p.date) else { return nil }
            return (date, p.equity)
        }
        guard let baselineDate = datedEquity.first?.date else { return nil }
        // Prefer Alpaca's reported base_value; fall back to the first equity
        // sample if it's missing/zero.
        let baseEquity = history.baseValue > 0 ? history.baseValue : datedEquity.first?.equity ?? 0
        guard baseEquity > 0 else { return nil }
        let portfolioCurve = datedEquity.map {
            ReturnPoint(
                date: $0.date,
                returnPct: ($0.equity / baseEquity - 1) * 100,
                equity: $0.equity
            )
        }

        var benchPoints: [ReturnPoint] = []
        if let benchmark = store.benchmark, !benchmark.points.isEmpty {
            let dated: [(Date, Double)] = benchmark.points.compactMap { p in
                guard let date = formatter.date(from: p.date) else { return nil }
                return (date, p.close)
            }
            if let baseline = dated.first(where: { $0.0 >= baselineDate })?.1 ?? dated.last?.1,
               baseline > 0 {
                benchPoints = dated
                    .filter { $0.0 >= baselineDate }
                    .map {
                        ReturnPoint(
                            date: $0.0,
                            returnPct: ($0.1 / baseline - 1) * 100,
                            equity: nil
                        )
                    }
            }
        }
        return PerformanceSeries(portfolio: portfolioCurve, benchmark: benchPoints)
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

    private var emptyChartMessage: String {
        if case .failed(let message) = store.loadState { return message }
        if store.portfolioHistory == nil {
            return "Performance history is momentarily unavailable. Pull to refresh to try again."
        }
        return "Place a paper trade and your account equity vs SPY will appear here."
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
            benchmarkReturn: benchmarkPoint?.returnPct
        )
    }

    private func latestPortfolioReturn(in series: PerformanceSeries) -> Double? {
        series.portfolio.last?.returnPct
    }

    private func latestBenchmarkReturn(in series: PerformanceSeries) -> Double? {
        series.benchmark.last?.returnPct
    }

    private func latestSpread(in series: PerformanceSeries) -> Double? {
        guard let portfolio = latestPortfolioReturn(in: series),
              let benchmark = latestBenchmarkReturn(in: series)
        else {
            return nil
        }
        return portfolio - benchmark
    }

    private func spreadPoints(in series: PerformanceSeries) -> [ReturnPoint] {
        series.portfolio.compactMap { point in
            guard let benchmark = nearestPoint(to: point.date, in: series.benchmark) else { return nil }
            return ReturnPoint(
                date: point.date,
                returnPct: point.returnPct - benchmark.returnPct,
                equity: nil
            )
        }
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

    private func metricTile(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
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

private struct LinkedAnalysisSheet: View {
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
        guard let sessionID = trade.sourceResearchSessionID else { return }
        var descriptor = FetchDescriptor<ResearchHistoryEntry>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        descriptor.fetchLimit = 1
        linkedEntry = (try? modelContext.fetch(descriptor))?.first
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
