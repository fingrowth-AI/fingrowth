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
        guard let headerIndex = rows.firstIndex(where: { $0.label == "BOLLINGER" }) else {
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
        guard let headerIndex = rows.firstIndex(where: { $0.label == "MACD" }) else {
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
        let rsi = rows.first { $0.label == "RSI" }
        XCTAssertEqual(rsi?.value, "79.87")
        let close = rows.first { $0.label == "LATEST_CLOSE" }
        XCTAssertEqual(close?.value, "312.51")
        let sample = rows.first { $0.label == "SAMPLE_SIZE" }
        XCTAssertEqual(sample?.value, "120")
    }
}
