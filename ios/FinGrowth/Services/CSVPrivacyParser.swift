import CryptoKit
import Foundation

// Heuristic CSV brokerage importer (P4-05).
//
// Stopgap parser for Fidelity / Schwab / Robinhood export formats. Produces
// two parallel structures from the same import:
//
//   * PrivateLedger — full ticker × quantity × cost basis, device-only.
//   * ShareableProfile — sector weights, value bucket, diversification-based
//     risk score. This is the redacted surface that's allowed to leave the
//     device.
//
// The parser is pure (no SwiftData I/O); callers insert the returned models
// into a ModelContext. P5-03 will replace the heuristic core with a Gemma 4
// powered parser but keep this Output contract.

enum CSVParserError: LocalizedError, Equatable {
    case empty
    case unrecognizedFormat(headerPreview: String)
    case noValidRows

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The CSV file is empty."
        case .unrecognizedFormat(let preview):
            return "Couldn't recognize this CSV format. Saw columns: \(preview). Supported: Fidelity, Schwab, Robinhood."
        case .noValidRows:
            return "No holdings found. Rows are present but none had a recognizable ticker and quantity."
        }
    }
}

struct ParsedCSVImport {
    let ledger: PrivateLedger
    let profile: ShareableProfile
    let format: CSVPrivacyParser.BrokerageFormat
}

enum CSVPrivacyParser {
    enum BrokerageFormat: String {
        case fidelity = "Fidelity"
        case schwab = "Charles Schwab"
        case robinhood = "Robinhood"
    }

    // MARK: - Public entry point

    static func parse(
        csv text: String,
        accountName: String? = nil,
        now: Date = .now
    ) throws -> ParsedCSVImport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CSVParserError.empty }

        let rows = parseRows(trimmed)
        guard let headerRow = rows.first(where: { !$0.allSatisfy(\.isEmpty) }) else {
            throw CSVParserError.empty
        }
        let normalizedHeaders = headerRow.map(normalize)
        guard let (format, columnMap) = detectFormat(headers: normalizedHeaders) else {
            let preview = headerRow.prefix(4).joined(separator: ", ")
            throw CSVParserError.unrecognizedFormat(headerPreview: preview)
        }

        let dataRows = rows.drop(while: { $0 != headerRow }).dropFirst()
        let holdings = dataRows.compactMap { row -> LedgerHolding? in
            extractHolding(from: row, columnMap: columnMap)
        }
        guard !holdings.isEmpty else { throw CSVParserError.noValidRows }

        let resolvedName = accountName?.nonEmptyTrimmed
            ?? format.rawValue + " Brokerage"

        let ledger = PrivateLedger(
            accountName: resolvedName,
            importedAt: now,
            rawCSVDigest: sha256(text),
            holdings: holdings
        )
        let profile = makeShareableProfile(from: holdings, now: now)
        return ParsedCSVImport(ledger: ledger, profile: profile, format: format)
    }

    // MARK: - Format detection

    struct ColumnMap {
        let symbolIndex: Int
        let quantityIndex: Int
        // Per-share cost. If the source only ships a total cost we divide
        // by quantity at extraction time.
        let costBasisIndex: Int
        let costBasisIsTotal: Bool
    }

    private static let fidelitySymbolHeaders: Set<String> = ["symbol"]
    private static let fidelityQuantityHeaders: Set<String> = ["quantity"]
    private static let fidelityCostHeaders: Set<String> = ["averagecostbasis", "averagecost"]
    private static let fidelityCostTotalHeaders: Set<String> = ["costbasistotal"]

    private static let schwabSymbolHeaders: Set<String> = ["symbol"]
    private static let schwabQuantityHeaders: Set<String> = ["quantity", "qty"]
    // Schwab's exports use "Cost Basis" as a total in dollars.
    private static let schwabCostTotalHeaders: Set<String> = ["costbasis"]
    private static let schwabSecurityHeader: Set<String> = ["securitytype"]

    private static let robinhoodSymbolHeaders: Set<String> = ["symbol", "instrument", "ticker"]
    private static let robinhoodQuantityHeaders: Set<String> = ["quantity", "shares"]
    private static let robinhoodCostHeaders: Set<String> = ["averagecost", "averagebuyprice"]

    private static func detectFormat(
        headers: [String]
    ) -> (BrokerageFormat, ColumnMap)? {
        let headerSet = Set(headers)

        // Fidelity prefers its per-share "Average Cost Basis"; falls back to
        // the total when only the aggregate column is exported.
        if let symbol = firstIndex(in: headers, anyOf: fidelitySymbolHeaders),
           let qty = firstIndex(in: headers, anyOf: fidelityQuantityHeaders),
           headerSet.contains("accountname") || headerSet.contains("accountnumber") {
            if let cost = firstIndex(in: headers, anyOf: fidelityCostHeaders) {
                return (.fidelity, ColumnMap(
                    symbolIndex: symbol,
                    quantityIndex: qty,
                    costBasisIndex: cost,
                    costBasisIsTotal: false
                ))
            } else if let cost = firstIndex(in: headers, anyOf: fidelityCostTotalHeaders) {
                return (.fidelity, ColumnMap(
                    symbolIndex: symbol,
                    quantityIndex: qty,
                    costBasisIndex: cost,
                    costBasisIsTotal: true
                ))
            }
        }

        // Schwab — discriminated from generic CSV by the "Security Type"
        // column its exports always include.
        if let symbol = firstIndex(in: headers, anyOf: schwabSymbolHeaders),
           let qty = firstIndex(in: headers, anyOf: schwabQuantityHeaders),
           let cost = firstIndex(in: headers, anyOf: schwabCostTotalHeaders),
           !headerSet.intersection(schwabSecurityHeader).isEmpty {
            return (.schwab, ColumnMap(
                symbolIndex: symbol,
                quantityIndex: qty,
                costBasisIndex: cost,
                costBasisIsTotal: true
            ))
        }

        // Robinhood — per-share average cost, no security-type column.
        if let symbol = firstIndex(in: headers, anyOf: robinhoodSymbolHeaders),
           let qty = firstIndex(in: headers, anyOf: robinhoodQuantityHeaders),
           let cost = firstIndex(in: headers, anyOf: robinhoodCostHeaders) {
            return (.robinhood, ColumnMap(
                symbolIndex: symbol,
                quantityIndex: qty,
                costBasisIndex: cost,
                costBasisIsTotal: false
            ))
        }

        return nil
    }

    private static func firstIndex(in headers: [String], anyOf candidates: Set<String>) -> Int? {
        headers.firstIndex(where: { candidates.contains($0) })
    }

    // MARK: - Row extraction

    private static func extractHolding(
        from row: [String],
        columnMap: ColumnMap
    ) -> LedgerHolding? {
        guard row.count > max(columnMap.symbolIndex, columnMap.quantityIndex, columnMap.costBasisIndex) else {
            return nil
        }
        let rawSymbol = row[columnMap.symbolIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = rawSymbol.uppercased()
        guard isValidTicker(symbol) else { return nil }

        guard let quantity = parseDecimal(row[columnMap.quantityIndex]), quantity > 0 else {
            return nil
        }
        guard let rawCost = parseDecimal(row[columnMap.costBasisIndex]), rawCost >= 0 else {
            return nil
        }
        let perShare = columnMap.costBasisIsTotal ? rawCost / quantity : rawCost
        return LedgerHolding(ticker: symbol, quantity: quantity, costBasis: perShare)
    }

    private static func isValidTicker(_ symbol: String) -> Bool {
        guard !symbol.isEmpty, symbol.count <= 10 else { return false }
        // A-Z, digits, dot/dash only (covers BRK.B, RDS-A style).
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return symbol.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - ShareableProfile

    private static func makeShareableProfile(
        from holdings: [LedgerHolding],
        now: Date
    ) -> ShareableProfile {
        let weights = SectorClassifier.weights(for: holdings)
        let totalValue = holdings.reduce(0) { $0 + $1.quantity * $1.costBasis }
        let bucket = ValueBucket.bucket(for: totalValue)
        let risk = diversificationRisk(weights: weights)

        let jsonData = (try? JSONSerialization.data(
            withJSONObject: weights,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"

        return ShareableProfile(
            totalValueBucket: bucket,
            sectorWeightsJSON: json,
            riskScore: risk,
            generatedAt: now
        )
    }

    // Herfindahl-style concentration score in [0, 1]. A single-stock
    // portfolio scores 1.0; a perfectly diversified one scores ~0.
    private static func diversificationRisk(weights: [String: Double]) -> Double {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let normalized = weights.values.map { $0 / total }
        let hhi = normalized.map { $0 * $0 }.reduce(0, +)
        return (hhi * 1000).rounded() / 1000
    }
}

// MARK: - CSV tokenizer

private extension CSVPrivacyParser {
    static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            let ch = Character(scalar)
            if inQuotes {
                if ch == "\"" {
                    // Peek-by-consume: an escaped quote is "" inside a field.
                    if let next = iterator.next() {
                        let nextCh = Character(next)
                        if nextCh == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            handleOutsideQuotes(nextCh, field: &field, row: &row, rows: &rows, inQuotes: &inQuotes)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                handleOutsideQuotes(ch, field: &field, row: &row, rows: &rows, inQuotes: &inQuotes)
            }
        }
        // Final field / row.
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) {
            rows.append(row)
        }
        return rows
    }

    static func handleOutsideQuotes(
        _ ch: Character,
        field: inout String,
        row: inout [String],
        rows: inout [[String]],
        inQuotes: inout Bool
    ) {
        switch ch {
        case "\"":
            inQuotes = true
        case ",":
            row.append(field)
            field = ""
        case "\n":
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
            field = ""
        case "\r":
            return
        default:
            field.append(ch)
        }
    }

    static func normalize(_ header: String) -> String {
        header
            .lowercased()
            .filter { !$0.isWhitespace && $0 != "_" && $0 != "-" && $0 != "/" && $0 != "$" }
    }

    static func parseDecimal(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }
        return Double(cleaned)
    }

    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Sector classification

// Stopgap GICS-style sector map for the popular tickers seeded in
// TickerCatalog. Anything outside the map collapses to "Other" so the
// generalized profile never exposes obscure single-issuer holdings.
enum SectorClassifier {
    private static let map: [String: String] = [
        "AAPL": "Information Technology",
        "MSFT": "Information Technology",
        "NVDA": "Information Technology",
        "AMD": "Information Technology",
        "INTC": "Information Technology",
        "ORCL": "Information Technology",
        "CRM": "Information Technology",
        "ADBE": "Information Technology",
        "QCOM": "Information Technology",
        "GOOGL": "Communication Services",
        "GOOG": "Communication Services",
        "META": "Communication Services",
        "NFLX": "Communication Services",
        "DIS": "Communication Services",
        "AMZN": "Consumer Discretionary",
        "TSLA": "Consumer Discretionary",
        "HD": "Consumer Discretionary",
        "WMT": "Consumer Staples",
        "PG": "Consumer Staples",
        "KO": "Consumer Staples",
        "PEP": "Consumer Staples",
        "COST": "Consumer Staples",
        "JPM": "Financials",
        "BAC": "Financials",
        "V": "Financials",
        "MA": "Financials",
        "BRK.B": "Financials",
        "JNJ": "Health Care",
        "PFE": "Health Care",
        "UNH": "Health Care",
        "XOM": "Energy",
    ]

    static func sector(for ticker: String) -> String {
        map[ticker.uppercased()] ?? "Other"
    }

    // Sector weights expressed as percentages summing to 100 (within
    // rounding). Returns an empty dict when the portfolio has zero value.
    static func weights(for holdings: [LedgerHolding]) -> [String: Double] {
        let totals = holdings.reduce(into: [String: Double]()) { acc, holding in
            let value = holding.quantity * holding.costBasis
            guard value > 0 else { return }
            acc[sector(for: holding.ticker), default: 0] += value
        }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [:] }
        // Compute percentages rounded to two decimals, then adjust the
        // largest bucket so the rounded values sum to exactly 100.
        var percents: [String: Double] = [:]
        for (sector, value) in totals {
            percents[sector] = (value / total * 10_000).rounded() / 100
        }
        let sum = percents.values.reduce(0, +)
        let delta = 100.0 - sum
        if abs(delta) > 0.0001, let topKey = percents.max(by: { $0.value < $1.value })?.key {
            percents[topKey] = ((percents[topKey] ?? 0) + delta).rounded(toPlaces: 2)
        }
        return percents
    }
}

// MARK: - Value buckets

enum ValueBucket {
    // Bucketed total-value bands. Stays coarse so the generalized profile
    // can't be deanonymized by joining against a public net-worth proxy.
    static func bucket(for value: Double) -> String {
        switch value {
        case ..<10_000: return "<10k"
        case ..<50_000: return "10k-50k"
        case ..<250_000: return "50k-250k"
        case ..<1_000_000: return "250k-1M"
        default: return "1M+"
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let multiplier = pow(10.0, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}
