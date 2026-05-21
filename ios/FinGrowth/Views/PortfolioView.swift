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
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(PortfolioSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

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
            do {
                let text = try readCSV(at: url)
                let imported = try CSVPrivacyParser.parse(
                    csv: text,
                    accountName: url.deletingPathExtension().lastPathComponent
                )
                modelContext.insert(imported.ledger)
                modelContext.insert(imported.profile)
                try modelContext.save()
                lastImportSummary = "Imported \(imported.ledger.holdings.count) holdings from \(imported.format.rawValue)."
            } catch let error as CSVParserError {
                csvImportError = error.errorDescription
            } catch {
                csvImportError = "Couldn't import CSV: \(error.localizedDescription)"
            }
        case .failure(let error):
            // User cancellation surfaces here too; suppress to avoid noise.
            if (error as NSError).code != NSUserCancelledError {
                csvImportError = error.localizedDescription
            }
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
        List {
            if paperTrades.isEmpty && store.orders.isEmpty {
                Section {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !paperTrades.isEmpty {
                Section("Placed in app") {
                    ForEach(paperTrades) { trade in
                        Button { onTapAnalysis(trade) } label: {
                            PaperTradeRow(trade: trade)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trade.ticker).font(.subheadline.weight(.semibold))
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

    var body: some View {
        List {
            Section("Cumulative return vs SPY") {
                if let chart = chartData {
                    performanceChart(chart)
                        .frame(height: 220)
                } else {
                    Text(emptyChartMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
    }

    fileprivate struct PerformanceSeries {
        var portfolio: [(date: Date, returnPct: Double)]
        var benchmark: [(date: Date, returnPct: Double)]
    }

    @ViewBuilder
    private func performanceChart(_ series: PerformanceSeries) -> some View {
        Chart {
            ForEach(Array(series.portfolio.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Return %", point.returnPct),
                    series: .value("Series", "Portfolio")
                )
                .foregroundStyle(by: .value("Series", "Portfolio"))
            }
            ForEach(Array(series.benchmark.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Return %", point.returnPct),
                    series: .value("Series", "SPY")
                )
                .foregroundStyle(by: .value("Series", "SPY"))
            }
        }
        .chartYAxisLabel("% return")
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7))
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
        let portfolioCurve = datedEquity.map { ($0.date, ($0.equity / baseEquity - 1) * 100) }

        var benchPoints: [(date: Date, returnPct: Double)] = []
        if let benchmark = store.benchmark, !benchmark.points.isEmpty {
            let dated: [(Date, Double)] = benchmark.points.compactMap { p in
                guard let date = formatter.date(from: p.date) else { return nil }
                return (date, p.close)
            }
            if let baseline = dated.first(where: { $0.0 >= baselineDate })?.1 ?? dated.last?.1,
               baseline > 0 {
                benchPoints = dated
                    .filter { $0.0 >= baselineDate }
                    .map { ($0.0, ($0.1 / baseline - 1) * 100) }
            }
        }
        return PerformanceSeries(portfolio: portfolioCurve, benchmark: benchPoints)
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

    private func statRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(valueColor ?? .primary)
        }
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
        !ticker.trimmingCharacters(in: .whitespaces).isEmpty
            && side != nil
            && (Double(quantity) ?? 0) > 0
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
            ForEach(entry.indicators.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key.uppercased()).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(stringValue(entry.indicators[key]))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
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

    private func stringValue(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .null: return "—"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(format: "%.2f", d)
        case .string(let s): return s
        case .array(let arr): return "[\(arr.count) values]"
        case .object: return "{…}"
        }
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

private func formatPrice(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

private func plLabel(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : "−"
    return sign + String(format: "$%.2f", abs(value))
}
