import SwiftUI

// V7-01: flattens a backend technical-indicator payload ([String: JSONValue])
// into display rows. Nested objects — MACD (line/signal/histogram) and
// Bollinger (upper/middle/lower) — are unpacked into indented sub-rows so the
// UI renders their real values instead of a raw "{…}" placeholder. The logic
// lives here, separate from the SwiftUI view, so it is unit-testable.

struct IndicatorRow: Equatable {
    enum Indent: Equatable { case top, sub }

    // Humanized label — "RSI (14-day)", "Latest close", "20-day average" — never
    // a raw backend key (V10-03).
    let label: String
    // nil marks a header row whose value lives in the sub-rows beneath it
    // (the unpacked object); scalar rows always carry a value.
    let value: String?
    let indent: Indent
    // V10-03: a plain-language interpretive tag shown alongside the value
    // ("Overbought", "Bullish", "Within bands"); nil for rows we don't interpret.
    var tag: String? = nil
    // V10-03: a one-line explanation revealed when the indicator is tapped.
    var explanation: String? = nil
    // V10-03: provenance/metadata (e.g. sample size) the UI de-emphasizes into a
    // footnote rather than presenting as a signal.
    var isMetadata: Bool = false
}

enum IndicatorFormatter {
    // Preferred sub-field ordering and human labels for the known nested
    // objects. The backend serializes the MACD line under the key "macd"
    // (same name as its parent), so without this map it would render as a
    // confusing "Macd" row — here it reads "Line". Keys not listed fall back
    // to a sorted, capitalized rendering.
    private static let nestedOrder: [String: [(key: String, label: String)]] = [
        "macd": [("macd", "Line"), ("signal", "Signal"), ("histogram", "Histogram")],
        "bollinger": [("lower", "Lower"), ("middle", "Middle"), ("upper", "Upper")],
    ]

    static func rows(from indicators: [String: JSONValue]) -> [IndicatorRow] {
        var rows: [IndicatorRow] = []
        for key in indicators.keys.sorted() {
            guard let value = indicators[key] else { continue }
            let label = humanLabel(for: key)
            switch value {
            case .object(let object):
                rows.append(IndicatorRow(
                    label: label,
                    value: nil,
                    indent: .top,
                    tag: objectTag(key: key, object: object, all: indicators),
                    explanation: explanation(for: key)
                ))
                for (subKey, subLabel) in orderedSubFields(parent: key, object: object) {
                    rows.append(IndicatorRow(label: subLabel, value: scalar(object[subKey]), indent: .sub))
                }
            case .array(let elements):
                // Unpack positionally rather than collapsing to a count, so the
                // actual values are visible.
                rows.append(IndicatorRow(label: label, value: nil, indent: .top))
                for (index, element) in elements.enumerated() {
                    rows.append(IndicatorRow(label: "[\(index)]", value: scalar(element), indent: .sub))
                }
            default:
                rows.append(IndicatorRow(
                    label: label,
                    value: scalar(value),
                    indent: .top,
                    tag: scalarTag(key: key, value: value),
                    explanation: explanation(for: key),
                    isMetadata: metadataKeys.contains(key.lowercased())
                ))
            }
        }
        return rows
    }

    // MARK: - V10-03: humanized labels

    // Plain-English labels for the indicators the analyst emits. Anything not
    // listed falls back to a de-keyed, capitalized rendering, so a raw key like
    // "SMA_20" can never reach the UI.
    private static let humanLabels: [String: String] = [
        "rsi": "RSI (14-day)",
        "macd": "MACD (12/26/9)",
        "bollinger": "Bollinger Bands (20, 2σ)",
        "sma_20": "20-day average",
        "latest_close": "Latest close",
        "sample_size": "Sample size",
    ]

    static func humanLabel(for key: String) -> String {
        humanLabels[key.lowercased()] ?? humanize(key)
    }

    // De-key a raw field name into a readable label: "some_raw_key" -> "Some raw
    // key", never SOME_RAW_KEY. Shared by top-level and nested fallbacks so a raw
    // key never reaches the UI (V10-03).
    static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ").lowercased()
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    // MARK: - V10-03: interpretive tags + explanations

    private static let metadataKeys: Set<String> = ["sample_size"]

    private static let explanations: [String: String] = [
        "rsi": "RSI gauges momentum on a 0–100 scale; above 70 is often read as "
            + "overbought, below 30 as oversold.",
        "macd": "MACD compares a fast and a slow moving average; a positive "
            + "histogram points to upward momentum, negative to downward.",
        "bollinger": "Bollinger Bands sit about ±2 standard deviations around the "
            + "20-day average; price outside the bands is unusually stretched.",
    ]

    static func explanation(for key: String) -> String? {
        explanations[key.lowercased()]
    }

    // Tag for an interpreted scalar indicator (currently RSI).
    private static func scalarTag(key: String, value: JSONValue) -> String? {
        guard key.lowercased() == "rsi", let rsi = doubleValue(value) else { return nil }
        if rsi >= 70 { return "Overbought" }
        if rsi <= 30 { return "Oversold" }
        return "Neutral"
    }

    // Tag for an interpreted object indicator (MACD via histogram sign; Bollinger
    // via the latest close versus the bands).
    private static func objectTag(
        key: String,
        object: [String: JSONValue],
        all: [String: JSONValue]
    ) -> String? {
        switch key.lowercased() {
        case "macd":
            guard let histogram = doubleValue(object["histogram"]) else { return nil }
            if histogram > 0 { return "Bullish" }
            if histogram < 0 { return "Bearish" }
            return "Flat"
        case "bollinger":
            guard let close = doubleValue(all["latest_close"]),
                  let lower = doubleValue(object["lower"]),
                  let upper = doubleValue(object["upper"]) else { return nil }
            if close > upper { return "Above upper band" }
            if close < lower { return "Below lower band" }
            return "Within bands"
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    private static func orderedSubFields(
        parent: String,
        object: [String: JSONValue]
    ) -> [(key: String, label: String)] {
        guard let preferred = nestedOrder[parent.lowercased()] else {
            // Unknown nested object: de-key every field so a raw key like
            // "trend_strength_score" never reaches the UI (V10-03).
            return object.keys.sorted().map { ($0, humanize($0)) }
        }
        // Keep only the keys actually present, in the preferred order, then
        // append any unexpected extras (also de-keyed) so nothing is silently
        // dropped — or shown as a raw key.
        var result = preferred.filter { object[$0.key] != nil }
        let known = Set(preferred.map(\.key))
        for extra in object.keys.sorted() where !known.contains(extra) {
            result.append((extra, humanize(extra)))
        }
        return result
    }

    // Renders a single JSON scalar. Objects/arrays are expanded inline as a
    // last resort so this never emits "{…}" or "[N values]".
    static func scalar(_ value: JSONValue?) -> String {
        guard let value else { return "—" }
        switch value {
        case .null:
            return "—"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(format: "%.2f", double)
        case .string(let string):
            return string
        case .array(let elements):
            return elements.map { scalar($0) }.joined(separator: ", ")
        case .object(let object):
            return object.keys.sorted()
                .map { "\($0): \(scalar(object[$0]))" }
                .joined(separator: ", ")
        }
    }
}

// Shared renderer for a technical-indicator payload. Every surface that shows
// indicators (Research result, history sheet, a paper trade's linked
// analysis) goes through this so the V7-01 unpacking — and the "never render a
// raw {…} placeholder" guarantee — holds everywhere, not just one screen.
struct IndicatorRowsView: View {
    let indicators: [String: JSONValue]
    var emptyMessage: String = "No indicator data returned."

    // V10-03: which interpreted rows have their explanation expanded. Indexed by
    // position in the signal-row list (rows carry no stable identity).
    @State private var expanded: Set<Int> = []

    var body: some View {
        if indicators.isEmpty {
            Text(emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            let rows = IndicatorFormatter.rows(from: indicators)
            let signalRows = rows.filter { !$0.isMetadata }
            let metadataRows = rows.filter { $0.isMetadata }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(signalRows.enumerated()), id: \.offset) { index, row in
                    rowView(index: index, row: row)
                }
                // V10-03: metadata (sample size, …) footnoted below the signals.
                if !metadataRows.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(Array(metadataRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label)
                            Spacer()
                            if let value = row.value { Text(value).monospacedDigit() }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(index: Int, row: IndicatorRow) -> some View {
        let canExpand = row.explanation != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.label)
                    .font(.subheadline.weight(row.indent == .top ? .medium : .regular))
                    .foregroundStyle(row.indent == .sub ? Color.secondary : Color.primary)
                    .padding(.leading, row.indent == .sub ? 14 : 0)
                if let tag = row.tag {
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tagColor(tag).opacity(0.15))
                        .foregroundStyle(tagColor(tag))
                        .clipShape(Capsule())
                }
                Spacer()
                if let value = row.value {
                    Text(value)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if canExpand {
                    Image(systemName: expanded.contains(index) ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if canExpand { toggle(index) } }
            if canExpand, expanded.contains(index), let explanation = row.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggle(_ index: Int) {
        if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
    }

    // Sentiment color for a tag — caution for stretched/bearish, positive for
    // bullish, neutral otherwise. Purely cosmetic; the tag text is the signal.
    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "Overbought", "Above upper band", "Bearish":
            return .orange
        case "Oversold", "Below lower band":
            return .blue
        case "Bullish":
            return .green
        default:
            return .secondary
        }
    }
}
