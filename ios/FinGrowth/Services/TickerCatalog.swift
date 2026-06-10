import Foundation

// Static autocomplete source for the Research query ticker field.
//
// The design doc treats ticker discovery as a P4-03 input ("ticker
// autocomplete"); a live symbol-search endpoint is out of scope. We seed a
// small catalog of well-known US tickers and let the view merge in recents
// pulled from SwiftData history at call time.
enum TickerCatalog {
    struct Entry: Hashable, Identifiable {
        let symbol: String
        let name: String
        var id: String { symbol }
    }

    static let popular: [Entry] = [
        Entry(symbol: "AAPL", name: "Apple Inc."),
        Entry(symbol: "MSFT", name: "Microsoft Corp."),
        Entry(symbol: "NVDA", name: "NVIDIA Corp."),
        Entry(symbol: "GOOGL", name: "Alphabet Inc. Class A"),
        Entry(symbol: "AMZN", name: "Amazon.com Inc."),
        Entry(symbol: "META", name: "Meta Platforms Inc."),
        Entry(symbol: "TSLA", name: "Tesla Inc."),
        Entry(symbol: "BRK.B", name: "Berkshire Hathaway B"),
        Entry(symbol: "JPM", name: "JPMorgan Chase & Co."),
        Entry(symbol: "V", name: "Visa Inc."),
        Entry(symbol: "JNJ", name: "Johnson & Johnson"),
        Entry(symbol: "XOM", name: "Exxon Mobil Corp."),
        Entry(symbol: "WMT", name: "Walmart Inc."),
        Entry(symbol: "PG", name: "Procter & Gamble Co."),
        Entry(symbol: "UNH", name: "UnitedHealth Group"),
        Entry(symbol: "MA", name: "Mastercard Inc."),
        Entry(symbol: "HD", name: "The Home Depot Inc."),
        Entry(symbol: "DIS", name: "The Walt Disney Co."),
        Entry(symbol: "NFLX", name: "Netflix Inc."),
        Entry(symbol: "AMD", name: "Advanced Micro Devices"),
        Entry(symbol: "INTC", name: "Intel Corp."),
        Entry(symbol: "BAC", name: "Bank of America Corp."),
        Entry(symbol: "PFE", name: "Pfizer Inc."),
        Entry(symbol: "KO", name: "The Coca-Cola Co."),
        Entry(symbol: "PEP", name: "PepsiCo Inc."),
        Entry(symbol: "ORCL", name: "Oracle Corp."),
        Entry(symbol: "CRM", name: "Salesforce Inc."),
        Entry(symbol: "ADBE", name: "Adobe Inc."),
        Entry(symbol: "COST", name: "Costco Wholesale Corp."),
        Entry(symbol: "QCOM", name: "Qualcomm Inc."),
    ]

    // Company name for a known symbol (result-screen header); nil when the
    // symbol isn't in the seeded catalog.
    static func name(for symbol: String) -> String? {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return popular.first { $0.symbol == upper }?.name
    }

    static func suggestions(
        for prefix: String,
        recents: [String] = [],
        limit: Int = 6
    ) -> [Entry] {
        let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let recentEntries: [Entry] = recents.compactMap { symbol in
            let upper = symbol.uppercased()
            if let known = popular.first(where: { $0.symbol == upper }) {
                return known
            }
            return Entry(symbol: upper, name: "Previously researched")
        }
        let pool = Array(NSOrderedSet(array: recentEntries + popular)) as? [Entry] ?? popular
        guard !normalized.isEmpty else {
            return Array(pool.prefix(limit))
        }
        let matched = pool.filter { entry in
            entry.symbol.hasPrefix(normalized)
                || entry.name.uppercased().contains(normalized)
        }
        return Array(matched.prefix(limit))
    }
}
