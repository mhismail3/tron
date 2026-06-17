import XCTest
@testable import TronMobile

@MainActor
final class AnimatedThinkingLineTests: XCTestCase {

    // MARK: - Parent AnimatedThinkingLine Tests

    func testAnimatedThinkingLineInstantiates() {
        let view = AnimatedThinkingLine()
        XCTAssertNotNil(view)
    }

    // MARK: - Individual Indicator View Tests

    func testNeuralSparkIndicatorInstantiates() {
        let view = NeuralSparkIndicator()
        XCTAssertNotNil(view)
    }
}
