import XCTest
@testable import FinGrowth

// Tests for V10-05 — the data behind the Swift Charts Bollinger visualization.
// The chart drawing itself is SwiftUI/Charts (verified by the build); here we
// pin the model that decides whether/what to draw.
final class BollingerChartModelTests: XCTestCase {

    private func payload(close: Double = 105.0) -> [String: JSONValue] {
        [
            "latest_close": .double(close),
            "bollinger": .object([
                "lower": .double(100.0),
                "middle": .double(110.0),
                "upper": .double(120.0),
            ]),
            "rsi": .double(55.0),
            "sample_size": .int(60),
        ]
    }

    func testBuildsPointFromIndicators() {
        let point = BollingerChartModel.make(from: payload(close: 105.0))
        XCTAssertEqual(point, BollingerChartPoint(lower: 100, middle: 110, upper: 120, close: 105))
    }

    func testReturnsNilWithoutBollinger() {
        XCTAssertNil(BollingerChartModel.make(from: ["latest_close": .double(105.0)]))
    }

    func testReturnsNilWithoutLatestClose() {
        let p: [String: JSONValue] = [
            "bollinger": .object([
                "lower": .double(100.0), "middle": .double(110.0), "upper": .double(120.0),
            ]),
        ]
        XCTAssertNil(BollingerChartModel.make(from: p))
    }

    func testCloseFractionWithinBand() {
        // close 105 in [100, 120] → 0.25
        let point = BollingerChartModel.make(from: payload(close: 105.0))!
        XCTAssertEqual(point.closeFraction, 0.25, accuracy: 1e-9)
        XCTAssertFalse(point.isAboveUpper)
        XCTAssertFalse(point.isBelowLower)
    }

    func testCloseAboveUpperClampsAndFlags() {
        let point = BollingerChartModel.make(from: payload(close: 130.0))!
        XCTAssertEqual(point.closeFraction, 1.0, accuracy: 1e-9)  // clamped
        XCTAssertTrue(point.isAboveUpper)
        XCTAssertFalse(point.isBelowLower)
    }

    func testCloseBelowLowerClampsAndFlags() {
        let point = BollingerChartModel.make(from: payload(close: 90.0))!
        XCTAssertEqual(point.closeFraction, 0.0, accuracy: 1e-9)  // clamped
        XCTAssertTrue(point.isBelowLower)
        XCTAssertFalse(point.isAboveUpper)
    }

    func testDegenerateBandFractionIsMidpoint() {
        let p: [String: JSONValue] = [
            "latest_close": .double(100.0),
            "bollinger": .object([
                "lower": .double(100.0), "middle": .double(100.0), "upper": .double(100.0),
            ]),
        ]
        let point = BollingerChartModel.make(from: p)
        XCTAssertNotNil(point)  // upper >= lower (equal) is allowed
        XCTAssertEqual(point?.closeFraction, 0.5)
    }
}
