import XCTest
@testable import TronMobile

final class DurationFormatterTests: XCTestCase {

    // MARK: - Sub-second

    func test_subSecond_returnsMs() {
        XCTAssertEqual(DurationFormatter.format(500), "500ms")
    }

    func test_zero_returnsZeroMs() {
        XCTAssertEqual(DurationFormatter.format(0), "0ms")
    }

    func test_999ms_returnsMs() {
        XCTAssertEqual(DurationFormatter.format(999), "999ms")
    }

    // MARK: - Seconds (full style)

    func test_exactSecond_returns1_0s() {
        XCTAssertEqual(DurationFormatter.format(1000), "1.0s")
    }

    func test_seconds_returnsDecimal() {
        XCTAssertEqual(DurationFormatter.format(2500), "2.5s")
    }

    func test_59seconds_returnsDecimal() {
        XCTAssertEqual(DurationFormatter.format(59999), "60.0s")
    }

    // MARK: - Minutes (full style)

    func test_minutes_returnsMinutesAndSeconds() {
        XCTAssertEqual(DurationFormatter.format(125000), "2m 5s")
    }

    func test_exactMinute_returnsMinutesAndZeroSeconds() {
        XCTAssertEqual(DurationFormatter.format(60000), "1m 0s")
    }

    func test_largeMinutes_returnsMinutesAndSeconds() {
        XCTAssertEqual(DurationFormatter.format(600000), "10m 0s")
    }

    // MARK: - Compact style

    func test_compact_subSecond_returnsMs() {
        XCTAssertEqual(DurationFormatter.format(500, style: .compact), "500ms")
    }

    func test_compact_seconds_returnsDecimal() {
        XCTAssertEqual(DurationFormatter.format(2500, style: .compact), "2.5s")
    }

    func test_compact_omitsMinutes() {
        XCTAssertEqual(DurationFormatter.format(125000, style: .compact), "125.0s")
    }
}
