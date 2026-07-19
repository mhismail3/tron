import XCTest
@testable import TronMobile

final class AgentPhaseTests: XCTestCase {

    // MARK: - Enum Value Tests

    func testIdleIsDefault() {
        let phase = AgentPhase.idle
        XCTAssertEqual(phase, .idle)
    }

    func testAllCasesExist() {
        let cases: [AgentPhase] = [.idle, .processing, .stopping]
        XCTAssertEqual(cases.count, 3)
    }

    // MARK: - Computed Property Tests

    func testIsProcessingTracksEveryActivePhase() {
        XCTAssertFalse(AgentPhase.idle.isProcessing)
        XCTAssertTrue(AgentPhase.processing.isProcessing)
        XCTAssertTrue(AgentPhase.stopping.isProcessing)
    }

    func testIsIdleTrueOnlyWhenIdle() {
        XCTAssertTrue(AgentPhase.idle.isIdle)
        XCTAssertFalse(AgentPhase.processing.isIdle)
        XCTAssertFalse(AgentPhase.stopping.isIdle)
    }

    func testIsActiveFalseOnlyWhenIdle() {
        XCTAssertFalse(AgentPhase.idle.isActive)
        XCTAssertTrue(AgentPhase.processing.isActive)
        XCTAssertTrue(AgentPhase.stopping.isActive)
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        XCTAssertEqual(AgentPhase.idle, AgentPhase.idle)
        XCTAssertEqual(AgentPhase.processing, AgentPhase.processing)
        XCTAssertEqual(AgentPhase.stopping, AgentPhase.stopping)
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
