import XCTest
@testable import FinGrowth

// V7-03: the result header shows a clear "as of close M/D" timestamp derived
// from the newest price bar's trading day.
final class DataFreshnessTests: XCTestCase {

    func testPriceDisplayFormatsAsOfClose() {
        let freshness = DataFreshness(priceAsOf: "2025-05-28")
        XCTAssertEqual(freshness.priceDisplay, "as of close 5/28")
    }

    func testPriceDisplayToleratesFullDatetime() {
        let freshness = DataFreshness(priceAsOf: "2025-12-01T20:15:00Z")
        XCTAssertEqual(freshness.priceDisplay, "as of close 12/1")
    }

    func testPriceDisplayNilWhenNoPriceData() {
        XCTAssertNil(DataFreshness(priceAsOf: nil).priceDisplay)
        XCTAssertNil(DataFreshness(priceAsOf: "").priceDisplay)
    }

    func testShortDateRejectsMalformedInput() {
        XCTAssertNil(DataFreshness.shortDate(fromISO: "not-a-date"))
        XCTAssertNil(DataFreshness.shortDate(fromISO: "2025/05/28"))
    }

    func testFreshnessDecodesFromSnakeCaseWire() throws {
        let json = """
        {"price_as_of": "2025-05-28",
         "price_fetched_at": "2025-05-28T20:15:00Z",
         "news_as_of": "2025-05-29T09:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let freshness = try decoder.decode(DataFreshness.self, from: json)
        XCTAssertEqual(freshness.priceAsOf, "2025-05-28")
        XCTAssertEqual(freshness.priceFetchedAt, "2025-05-28T20:15:00Z")
        XCTAssertEqual(freshness.newsAsOf, "2025-05-29T09:00:00Z")
        XCTAssertEqual(freshness.priceDisplay, "as of close 5/28")
    }

    func testResearchDataDecodesWithoutFreshnessField() throws {
        // The partial-research SSE frame omits freshness; ResearchData must
        // still decode (freshness == nil) rather than throw keyNotFound.
        let json = #"{"filings": [], "news": []}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let research = try decoder.decode(ResearchData.self, from: json)
        XCTAssertNil(research.freshness)
    }
}
