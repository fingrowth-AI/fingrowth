import Foundation

// V12-02: Outcome tracking and personal hit-rate.
//
// Closes the research-to-outcome loop V12-01 opened. A paper trade carries the
// user's thesis and a side; this engine deterministically decides whether that
// thesis was borne out by the *realized* trade — no LLM judgment, just
// arithmetic on the user's own fills.
//
// "Closed" means a round trip: an opening order (buy = bullish, sell = bearish/
// short) matched by a later opposite order on the same ticker. Both legs already
// store `filledAvgPrice`, so the realized direction is known without any price
// feed. The thesis is confirmed when the price moved the way the side bet:
//   * opened long (buy)  → confirmed if it was closed *higher* than entry
//   * opened short (sell) → confirmed if it was closed *lower* than entry
// Matching is FIFO by filled quantity, so partial closes and multiple lots
// resolve to one outcome per opening order (quantity-weighted exit).

enum ThesisOutcome: String, Equatable, Sendable {
    case confirmed
    case notConfirmed

    var label: String {
        switch self {
        case .confirmed: return "Thesis confirmed"
        case .notConfirmed: return "Not confirmed"
        }
    }
}

// A completed round trip, attributed to the opening order that carried the
// thesis. One per opening order that has been (at least partially) closed.
struct ClosedThesis: Equatable, Sendable, Identifiable {
    let openingOrderID: String
    let ticker: String
    let openingSide: String  // "buy" (long) | "sell" (short)
    let entryPrice: Double
    let exitPrice: Double     // quantity-weighted across closing legs
    let quantity: Double      // total closed quantity
    let thesis: String
    let outcome: ThesisOutcome

    var id: String { openingOrderID }
}

struct ThesisHitRate: Equatable, Sendable {
    let confirmed: Int
    let total: Int

    var rate: Double { total == 0 ? 0 : Double(confirmed) / Double(total) }

    // Plain-language summary for the header.
    var display: String {
        guard total > 0 else { return "No closed theses yet" }
        return "\(confirmed)/\(total) confirmed (\(Int((rate * 100).rounded()))%)"
    }
}

enum ThesisOutcomeEngine {

    /// Deterministic direction check for one round trip. Equal prices count as
    /// not confirmed — the thesis direction didn't play out.
    static func evaluate(openingSide: String, entryPrice: Double, exitPrice: Double) -> ThesisOutcome {
        if openingSide.lowercased() == "buy" {
            return exitPrice > entryPrice ? .confirmed : .notConfirmed
        }
        // sell-to-open (short): the bet was that price falls.
        return exitPrice < entryPrice ? .confirmed : .notConfirmed
    }

    /// All closed round trips across the given trade records, one entry per
    /// opening order that has been matched by later opposite fills. Open or
    /// unfilled positions produce nothing (they aren't yet decidable).
    static func closedTheses(from records: [PaperTradeRecord]) -> [ClosedThesis] {
        // Only filled legs with a known fill price and quantity can be matched.
        let fillable = records
            .filter { $0.filledQty > 0 && ($0.filledAvgPrice ?? 0) > 0 }
            .sorted { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt { return lhs.submittedAt < rhs.submittedAt }
                return lhs.brokerOrderID < rhs.brokerOrderID
            }

        // FIFO open lots per ticker, tagged with the opening order they came from.
        struct Lot { let record: PaperTradeRecord; var remaining: Double; let price: Double }
        var lotsByTicker: [String: [Lot]] = [:]
        // Closing legs accumulated against each opening order: (qty, exitPrice).
        var legsByOpening: [String: [(qty: Double, exit: Double)]] = [:]
        // Quantity each opening order actually opened, so we can tell a fully
        // closed thesis from one with shares still on the book.
        var openedQtyByID: [String: Double] = [:]
        // Preserve first-seen order of opening records so output is stable.
        var openingOrder: [PaperTradeRecord] = []
        var seenOpening: Set<String> = []

        for record in fillable {
            let ticker = record.ticker.uppercased()
            let price = record.filledAvgPrice ?? 0
            var remaining = record.filledQty
            var lots = lotsByTicker[ticker] ?? []

            // A record closes against open lots only when it's the opposite side.
            while remaining > 0, let first = lots.first, first.record.side.lowercased() != record.side.lowercased() {
                let matched = min(first.remaining, remaining)
                let openingID = first.record.brokerOrderID
                legsByOpening[openingID, default: []].append((qty: matched, exit: price))
                if seenOpening.insert(openingID).inserted { openingOrder.append(first.record) }

                remaining -= matched
                if matched >= first.remaining {
                    lots.removeFirst()
                } else {
                    lots[0] = Lot(record: first.record, remaining: first.remaining - matched, price: first.price)
                }
            }

            // Any unmatched remainder opens a new lot in this record's direction
            // (a fresh position, or a reversal beyond the closed quantity).
            if remaining > 0 {
                lots.append(Lot(record: record, remaining: remaining, price: price))
                openedQtyByID[record.brokerOrderID, default: 0] += remaining
            }
            lotsByTicker[ticker] = lots
        }

        let epsilon = 1e-9
        return openingOrder.compactMap { opening -> ClosedThesis? in
            // P2: only score trades that actually carry a user thesis. Pre-V12-01
            // records migrated with thesis "" are round trips, not theses.
            guard !opening.thesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let legs = legsByOpening[opening.brokerOrderID], !legs.isEmpty else { return nil }
            let totalQty = legs.reduce(0.0) { $0 + $1.qty }
            // P1: a thesis is "closed" only when the whole opened quantity has been
            // matched by closing fills — a partial close leaves it still open.
            let openedQty = openedQtyByID[opening.brokerOrderID] ?? 0
            guard openedQty > 0, totalQty >= openedQty - epsilon else { return nil }
            let weightedExit = legs.reduce(0.0) { $0 + $1.exit * $1.qty } / totalQty
            let entry = opening.filledAvgPrice ?? 0
            return ClosedThesis(
                openingOrderID: opening.brokerOrderID,
                ticker: opening.ticker.uppercased(),
                openingSide: opening.side,
                entryPrice: entry,
                exitPrice: weightedExit,
                quantity: totalQty,
                thesis: opening.thesis,
                outcome: evaluate(openingSide: opening.side, entryPrice: entry, exitPrice: weightedExit)
            )
        }
    }

    /// Running hit-rate across the closed theses.
    static func hitRate(_ closed: [ClosedThesis]) -> ThesisHitRate {
        let confirmed = closed.filter { $0.outcome == .confirmed }.count
        return ThesisHitRate(confirmed: confirmed, total: closed.count)
    }

    /// Convenience: outcome keyed by the opening order's id, for per-row badges.
    static func outcomesByOpeningOrderID(from records: [PaperTradeRecord]) -> [String: ThesisOutcome] {
        Dictionary(
            closedTheses(from: records).map { ($0.openingOrderID, $0.outcome) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
