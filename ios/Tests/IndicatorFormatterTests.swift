import XCTest
@testable import FinGrowth

// V7-01: nested indicator objects (MACD, Bollinger) must render their real
// values as sub-rows — never a raw "{…}" or "[N values]" placeholder.
final class IndicatorFormatterTests: XCTestCase {

    private func payload() -> [String: JSONValue] {
        [
            "rsi": .double(79.87),
            "latest_close": .double(312.51),
            "sample_size": .int(120),
            "macd": .object([
                "macd": .double(10.4412),
                "signal": .double(8.21),
                "histogram": .double(2.23),
            ]),
            "bollinger": .object([
                "upper": .double(330.5),
                "middle": .double(310.0),
                "lower": .double(289.5),
            ]),
        ]
    }

    func testBollingerUnpacksIntoLowerMiddleUpperSubRows() {
        let rows = IndicatorFormatter.rows(from: payload())
        guard let headerIndex = rows.firstIndex(where: { $0.label.hasPrefix("Bollinger") }) else {
            return XCTFail("missing Bollinger header row")
        }
        // Header carries no inline value — the bands live in the sub-rows.
        XCTAssertNil(rows[headerIndex].value)
        XCTAssertEqual(rows[headerIndex].indent, .top)

        let subs = Array(rows[(headerIndex + 1)...].prefix(3))
        XCTAssertEqual(subs.map(\.label), ["Lower", "Middle", "Upper"])
        XCTAssertEqual(subs.map(\.value), ["289.50", "310.00", "330.50"])
        XCTAssertTrue(subs.allSatisfy { $0.indent == .sub })
    }

    func testMACDUnpacksIntoLineSignalHistogramSubRows() {
        let rows = IndicatorFormatter.rows(from: payload())
        guard let headerIndex = rows.firstIndex(where: { $0.label.hasPrefix("MACD") }) else {
            return XCTFail("missing MACD header row")
        }
        XCTAssertNil(rows[headerIndex].value)

        let subs = Array(rows[(headerIndex + 1)...].prefix(3))
        XCTAssertEqual(subs.map(\.label), ["Line", "Signal", "Histogram"])
        XCTAssertEqual(subs.map(\.value), ["10.44", "8.21", "2.23"])
    }

    func testNoObjectOrArrayPlaceholderEverAppears() {
        let rows = IndicatorFormatter.rows(from: payload())
        for row in rows {
            XCTAssertNotEqual(row.value, "{…}")
            XCTAssertNotEqual(row.label, "{…}")
            if let value = row.value {
                XCTAssertFalse(value.contains("{"), "placeholder leaked into \(row.label): \(value)")
                XCTAssertFalse(value.contains("values]"), "placeholder leaked into \(row.label): \(value)")
            }
        }
    }

    func testScalarNeverEmitsObjectPlaceholder() {
        // Even a stray nested object scalar is expanded inline, not collapsed.
        let inline = IndicatorFormatter.scalar(.object(["a": .int(1), "b": .int(2)]))
        XCTAssertEqual(inline, "a: 1, b: 2")
        XCTAssertFalse(inline.contains("…"))
    }

    func testTopLevelScalarsRenderTheirValues() {
        let rows = IndicatorFormatter.rows(from: payload())
        let rsi = rows.first { $0.label.hasPrefix("RSI") }
        XCTAssertEqual(rsi?.value, "79.87")
        let close = rows.first { $0.label == "Latest close" }
        XCTAssertEqual(close?.value, "312.51")
        let sample = rows.first { $0.label == "Sample size" }
        XCTAssertEqual(sample?.value, "120")
    }

    // MARK: - V10-03: inline interpretation per indicator

    func testRSIMACDBollingerEachCarryAnInterpretiveTag() {
        // AC1: RSI, MACD, and Bollinger each show a tag alongside the value.
        let rows = IndicatorFormatter.rows(from: payload())
        let rsi = rows.first { $0.label.hasPrefix("RSI") }
        let macd = rows.first { $0.label.hasPrefix("MACD") }
        let bollinger = rows.first { $0.label.hasPrefix("Bollinger") }

        XCTAssertEqual(rsi?.tag, "Overbought")       // 79.87 ≥ 70
        XCTAssertEqual(macd?.tag, "Bullish")         // histogram 2.23 > 0
        XCTAssertEqual(bollinger?.tag, "Within bands")  // close 312.51 ∈ [289.5, 330.5]
    }

    func testEachInterpretedIndicatorHasAOneLineExplanation() {
        // AC2: tapping reveals a one-line plain explanation (the data behind it).
        let rows = IndicatorFormatter.rows(from: payload())
        for prefix in ["RSI", "MACD", "Bollinger"] {
            let row = rows.first { $0.label.hasPrefix(prefix) }
            let explanation = row?.explanation
            XCTAssertNotNil(explanation, "\(prefix) should have an explanation")
            XCTAssertFalse(explanation?.isEmpty ?? true)
            // One line — no embedded newlines.
            XCTAssertFalse(explanation?.contains("\n") ?? false)
        }
    }

    func testLabelsAreHumanizedNeverRawKeys() {
        // AC3: labels read as "Latest close", "20-day average", "RSI (14-day)".
        let withSMA = payload().merging(["sma_20": .double(305.0)]) { _, new in new }
        let labels = Set(IndicatorFormatter.rows(from: withSMA).map(\.label))

        XCTAssertTrue(labels.contains("RSI (14-day)"))
        XCTAssertTrue(labels.contains("Latest close"))
        XCTAssertTrue(labels.contains("20-day average"))
        XCTAssertTrue(labels.contains("Sample size"))
        // No raw backend key survives as a label.
        for raw in ["RSI", "LATEST_CLOSE", "SMA_20", "SAMPLE_SIZE", "MACD", "BOLLINGER"] {
            XCTAssertFalse(labels.contains(raw), "raw key leaked as a label: \(raw)")
        }
    }

    func testNestedFallbackFieldsAreHumanizedNotRawKeys() {
        // P3: unexpected nested fields (not in the curated MACD/Bollinger map) and
        // unknown nested objects must still be de-keyed — never raw underscores.
        let p: [String: JSONValue] = [
            "macd": .object([
                "macd": .double(1.0), "signal": .double(0.5), "histogram": .double(0.5),
                "trend_strength_score": .double(0.8),  // unexpected extra field
            ]),
            "momentum_score": .object(["raw_value": .double(0.42)]),  // unknown parent
        ]
        let labels = IndicatorFormatter.rows(from: p).map(\.label)

        for label in labels {
            XCTAssertFalse(label.contains("_"), "raw key leaked into label: \(label)")
        }
        XCTAssertTrue(labels.contains("Trend strength score"))  // extra MACD field
        XCTAssertTrue(labels.contains("Momentum score"))        // unknown parent header
        XCTAssertTrue(labels.contains("Raw value"))             // unknown parent sub-field
    }

    func testSampleSizeIsFlaggedAsMetadata() {
        // AC4: metadata like sample size is de-emphasized (footnoted by the view).
        let rows = IndicatorFormatter.rows(from: payload())
        let sample = rows.first { $0.label == "Sample size" }
        XCTAssertEqual(sample?.isMetadata, true)
        // The interpreted signals are not metadata.
        for prefix in ["RSI", "MACD", "Bollinger", "Latest close"] {
            let row = rows.first { $0.label.hasPrefix(prefix) }
            XCTAssertEqual(row?.isMetadata, false, "\(prefix) must not be metadata")
        }
    }

    func testRSITagReflectsThreshold() {
        func tag(_ rsi: Double) -> String? {
            IndicatorFormatter.rows(from: ["rsi": .double(rsi)])
                .first { $0.label.hasPrefix("RSI") }?.tag
        }
        XCTAssertEqual(tag(22.0), "Oversold")
        XCTAssertEqual(tag(50.0), "Neutral")
        XCTAssertEqual(tag(81.0), "Overbought")
    }

    func testBollingerTagReflectsClosePosition() {
        func tag(close: Double) -> String? {
            let p: [String: JSONValue] = [
                "latest_close": .double(close),
                "bollinger": .object([
                    "lower": .double(100.0), "middle": .double(110.0), "upper": .double(120.0),
                ]),
            ]
            return IndicatorFormatter.rows(from: p).first { $0.label.hasPrefix("Bollinger") }?.tag
        }
        XCTAssertEqual(tag(close: 125.0), "Above upper band")
        XCTAssertEqual(tag(close: 95.0), "Below lower band")
        XCTAssertEqual(tag(close: 110.0), "Within bands")
    }
}
