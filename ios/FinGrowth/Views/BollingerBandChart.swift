import Charts
import SwiftUI

// V10-05: a small, native Swift Charts visualization — where the latest close
// sits inside the Bollinger band range — to convey the picture faster than a
// row of numbers, matching the Stocks-app aesthetic. The drawing data is
// extracted into a testable model; the view uses only semantic colors so it
// adapts to dark mode automatically.

struct BollingerChartPoint: Equatable {
    let lower: Double
    let middle: Double
    let upper: Double
    let close: Double

    // Where the close sits across the band, clamped to [0, 1]: 0 at/below the
    // lower band, 1 at/above the upper band.
    var closeFraction: Double {
        guard upper > lower else { return 0.5 }
        return min(1, max(0, (close - lower) / (upper - lower)))
    }

    var isAboveUpper: Bool { close > upper }
    var isBelowLower: Bool { close < lower }
}

enum BollingerChartModel {
    /// Build the chart point from a technical-indicator payload, or nil when the
    /// Bollinger bands / latest close aren't present (e.g. a short series).
    static func make(from indicators: [String: JSONValue]) -> BollingerChartPoint? {
        guard case .object(let bands)? = indicators["bollinger"],
              let lower = numeric(bands["lower"]),
              let middle = numeric(bands["middle"]),
              let upper = numeric(bands["upper"]),
              let close = numeric(indicators["latest_close"]),
              upper >= lower
        else { return nil }
        return BollingerChartPoint(lower: lower, middle: middle, upper: upper, close: close)
    }

    static func numeric(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

struct BollingerBandChart: View {
    let point: BollingerChartPoint

    private let lane = "band"

    var body: some View {
        Chart {
            // The band as a horizontal range from lower to upper.
            BarMark(
                xStart: .value("Lower", point.lower),
                xEnd: .value("Upper", point.upper),
                y: .value("", lane),
                height: 12
            )
            .foregroundStyle(Color.secondary.opacity(0.22))
            .cornerRadius(6)

            // The 20-day midline (SMA) as a dashed rule.
            RuleMark(x: .value("Middle", point.middle))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .foregroundStyle(Color.secondary)

            // The latest close — the focal point — emphasized and labelled.
            PointMark(
                x: .value("Close", point.close),
                y: .value("", lane)
            )
            .symbolSize(130)
            .foregroundStyle(closeColor)
            .annotation(position: .top, alignment: .center, spacing: 2) {
                Text(point.close, format: .number.precision(.fractionLength(2)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .chartXScale(domain: domain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [point.lower, point.middle, point.upper]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v, format: .number.precision(.fractionLength(2)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 72)
        .accessibilityElement()
        .accessibilityLabel("Latest close \(string(point.close)) versus Bollinger bands "
            + "from \(string(point.lower)) to \(string(point.upper))")
    }

    // Stretched closes (outside the bands) read as caution; otherwise the accent.
    // Both are semantic colors, so the chart inverts cleanly in dark mode.
    private var closeColor: Color {
        (point.isAboveUpper || point.isBelowLower) ? .orange : .accentColor
    }

    // Pad the axis so the band — and the close, even when outside it — both fit.
    private var domain: ClosedRange<Double> {
        let lo = min(point.lower, point.close)
        let hi = max(point.upper, point.close)
        let pad = max((hi - lo) * 0.08, 0.01)
        return (lo - pad)...(hi + pad)
    }

    private func string(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
