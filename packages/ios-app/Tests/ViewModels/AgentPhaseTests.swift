import XCTest
@testable import TronMobile

final class AgentPhaseTests: XCTestCase {

    // MARK: - Enum Value Tests

    func testIdleIsDefault() {
        let phase = AgentPhase.idle
        XCTAssertEqual(phase, .idle)
    }

    func testAllCasesExist() {
        let cases: [AgentPhase] = [.idle, .processing]
        XCTAssertEqual(cases.count, 2)
    }

    // MARK: - Computed Property Tests

    func testIsProcessingTrueOnlyWhenProcessing() {
        XCTAssertFalse(AgentPhase.idle.isProcessing)
        XCTAssertTrue(AgentPhase.processing.isProcessing)
    }

    func testIsIdleTrueOnlyWhenIdle() {
        XCTAssertTrue(AgentPhase.idle.isIdle)
        XCTAssertFalse(AgentPhase.processing.isIdle)
    }

    func testIsActiveFalseOnlyWhenIdle() {
        XCTAssertFalse(AgentPhase.idle.isActive)
        XCTAssertTrue(AgentPhase.processing.isActive)
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        XCTAssertEqual(AgentPhase.idle, AgentPhase.idle)
        XCTAssertEqual(AgentPhase.processing, AgentPhase.processing)
        XCTAssertNotEqual(AgentPhase.idle, AgentPhase.processing)
    }

    // MARK: - Sendable Tests

    func testSendable() {
        // AgentPhase conforms to Sendable — this compiles = passes
        let phase: AgentPhase = .idle
        Task { @Sendable in
            _ = phase
        }
    }
}
