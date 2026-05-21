import Foundation
import Observation
import SwiftData

// State container for the Portfolio tab (P4-04).
//
// Owns the remote refresh lifecycle for positions / orders / benchmark prices
// and the local persistence of placed paper trades. The view layer reads the
// @Observable state and triggers `refresh()` / `placeOrder(...)`.

@MainActor
@Observable
final class PortfolioStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var positions: [BrokerPosition] = []
    private(set) var orders: [BrokerOrder] = []
    private(set) var benchmark: BenchmarkSeries?
    private(set) var loadState: LoadState = .idle
    private(set) var lastRefreshedAt: Date?
    var submitError: String?

    private let client: PaperTradingService
    private let context: ModelContext

    init(client: PaperTradingService, context: ModelContext) {
        self.client = client
        self.context = context
    }

    var isLoading: Bool { loadState == .loading }

    // MARK: - Remote sync

    func refresh(benchmarkDays: Int = 30) async {
        loadState = .loading
        // Positions + orders are the critical path — a failure there means
        // Holdings/Orders can't render. The benchmark is best-effort: Alpha
        // Vantage's free tier rate-limits aggressively, and that shouldn't
        // bring down the rest of the tab.
        do {
            async let positionsFetch = client.listPositions()
            async let ordersFetch = client.listOrders(limit: 100, status: "all")
            let (pos, ord) = try await (positionsFetch, ordersFetch)
            positions = pos
            orders = ord
            reconcileLocalRecords(with: ord)
            captureSnapshot(from: pos)
            lastRefreshedAt = Date()
            loadState = .loaded
        } catch let error as PaperTradingClientError {
            loadState = .failed(message: error.errorDescription ?? "Failed to load portfolio.")
            return
        } catch {
            loadState = .failed(message: error.localizedDescription)
            return
        }
        do {
            benchmark = try await client.benchmark(symbol: "SPY", days: benchmarkDays)
        } catch {
            // Leave loadState = .loaded; the Performance sub-view surfaces a
            // softer "benchmark unavailable" message via its empty state.
            benchmark = nil
        }
    }

    // Bring local PaperTradeRecords up to date with the broker's view: an order
    // first returned as "accepted" (filledQty 0) is later filled, and the
    // performance curve / order list must reflect that. Match by brokerOrderID.
    private func reconcileLocalRecords(with remoteOrders: [BrokerOrder]) {
        let byID = Dictionary(remoteOrders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard !byID.isEmpty else { return }
        let descriptor = FetchDescriptor<PaperTradeRecord>()
        guard let records = try? context.fetch(descriptor), !records.isEmpty else { return }
        var dirty = false
        for record in records {
            guard let remote = byID[record.brokerOrderID] else { continue }
            if record.status != remote.status
                || record.filledQty != remote.filledQty
                || record.filledAvgPrice != remote.filledAvgPrice {
                record.status = remote.status
                record.filledQty = remote.filledQty
                record.filledAvgPrice = remote.filledAvgPrice
                dirty = true
            }
        }
        if dirty { try? context.save() }
    }

    // Persist one snapshot per calendar day. Replaces an existing same-day
    // snapshot so repeated refreshes don't accumulate duplicate points and the
    // latest intraday value wins.
    private func captureSnapshot(from positions: [BrokerPosition]) {
        let marketValue = positions.compactMap(\.marketValue).reduce(0, +)
        let costBasis = positions.compactMap(\.costBasis).reduce(0, +)
        let day = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<PortfolioSnapshot>(
            predicate: #Predicate { $0.capturedDay == day }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.marketValue = marketValue
            existing.costBasis = costBasis
        } else {
            context.insert(PortfolioSnapshot(
                capturedDay: day,
                marketValue: marketValue,
                costBasis: costBasis
            ))
        }
        try? context.save()
    }

    // MARK: - Place a paper trade

    @discardableResult
    func placeOrder(
        ticker: String,
        qty: Double,
        side: String,
        source: PaperTradePrefill.Pending? = nil
    ) async -> BrokerOrder? {
        submitError = nil
        do {
            let order = try await client.placeOrder(
                PlacePaperOrderRequest(
                    ticker: ticker.uppercased(),
                    quantity: qty,
                    side: side
                )
            )
            persistLocalRecord(order: order, source: source)
            // Refresh in the background — fire and forget so the caller's UI
            // isn't blocked on Alpaca's order propagation delay.
            Task { await self.refresh() }
            return order
        } catch let error as PaperTradingClientError {
            submitError = error.errorDescription
            return nil
        } catch {
            submitError = error.localizedDescription
            return nil
        }
    }

    private func persistLocalRecord(order: BrokerOrder, source: PaperTradePrefill.Pending?) {
        let record = PaperTradeRecord(
            brokerOrderID: order.id,
            ticker: order.symbol,
            qty: order.qty,
            side: order.side,
            status: order.status,
            submittedAt: order.submittedAt ?? Date(),
            filledQty: order.filledQty,
            filledAvgPrice: order.filledAvgPrice,
            sourceQuery: source?.sourceQuery ?? "",
            sourceAnalysisType: source?.sourceAnalysisType ?? .general,
            sourceConfidence: source?.sourceConfidence ?? "",
            sourceResearchSessionID: source?.sourceResearchSessionID
        )
        context.insert(record)
        do {
            try context.save()
        } catch {
            // Local persistence is best-effort. Surface as a soft error;
            // remote order succeeded so we don't want to misreport failure.
            submitError = "Local trade record failed to save: \(error.localizedDescription)"
        }
    }
}
