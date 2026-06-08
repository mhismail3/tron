import XCTest
@testable import TronMobile

@available(iOS 26.0, *)
final class CardEntranceModifierTests: XCTestCase {
    func testEntranceMotionStaysSubtle() {
        XCTAssertLessThanOrEqual(CardEntranceConfiguration.initialOffsetY, 16)
        XCTAssertGreaterThanOrEqual(CardEntranceConfiguration.dampingFraction, 0.85)
        XCTAssertLessThanOrEqual(CardEntranceConfiguration.response, 0.35)
    }

    func testStaggerDelayIsClamped() {
        XCTAssertEqual(CardEntranceConfiguration.delay(for: -1), 0)
        XCTAssertEqual(CardEntranceConfiguration.delay(for: 0), 0)
        XCTAssertEqual(CardEntranceConfiguration.delay(for: 2), 0.07, accuracy: 0.0001)
        XCTAssertEqual(
            CardEntranceConfiguration.delay(for: 100),
            CardEntranceConfiguration.maxStaggerDelay,
            accuracy: 0.0001
        )
    }
}
