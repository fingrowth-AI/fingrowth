import SwiftUI

// V7-01: flattens a backend technical-indicator payload ([String: JSONValue])
// into display rows. Nested objects — MACD (line/signal/histogram) and
// Bollinger (upper/middle/lower) — are unpacked into indented sub-rows so the
// UI renders their real values instead of a raw "{…}" placeholder. The logic
// lives here, separate from the SwiftUI view, so it is unit-testable.

struct IndicatorRow: Equatable {
    enum Indent: Equatable { case top, sub }

    let label: String
    // nil marks a header row whose value lives in the sub-rows beneath it
    // (the unpacked object); scalar rows always carry a value.
    let value: String?
    let indent: Indent
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
            switch value {
            case .object(let object):
                rows.append(IndicatorRow(label: key.uppercased(), value: nil, indent: .top))
                for (subKey, subLabel) in orderedSubFields(parent: key, object: object) {
                    rows.append(IndicatorRow(label: subLabel, value: scalar(object[subKey]), indent: .sub))
                }
            case .array(let elements):
                // Unpack positionally rather than collapsing to a count, so the
                // actual values are visible.
                rows.append(IndicatorRow(label: key.uppercased(), value: nil, indent: .top))
                for (index, element) in elements.enumerated() {
                    rows.append(IndicatorRow(label: "[\(index)]", value: scalar(element), indent: .sub))
                }
            default:
                rows.append(IndicatorRow(label: key.uppercased(), value: scalar(value), indent: .top))
            }
        }
        return rows
    }

    private static func orderedSubFields(
        parent: String,
        object: [String: JSONValue]
    ) -> [(key: String, label: String)] {
        guard let preferred = nestedOrder[parent.lowercased()] else {
            return object.keys.sorted().map { ($0, $0.capitalized) }
        }
        // Keep only the keys actually present, in the preferred order, then
        // append any unexpected extras so nothing is silently dropped.
        var result = preferred.filter { object[$0.key] != nil }
        let known = Set(preferred.map(\.key))
        for extra in object.keys.sorted() where !known.contains(extra) {
            result.append((extra, extra.capitalized))
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

    var body: some View {
        if indicators.isEmpty {
            Text(emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // Rows have no stable identity of their own, so index the
            // flattened list for ForEach.
            let rows = IndicatorFormatter.rows(from: indicators)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.subheadline.weight(row.indent == .top ? .medium : .regular))
                            .foregroundStyle(row.indent == .sub ? Color.secondary : Color.primary)
                            .padding(.leading, row.indent == .sub ? 14 : 0)
                        Spacer()
                        if let value = row.value {
                            Text(value)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
