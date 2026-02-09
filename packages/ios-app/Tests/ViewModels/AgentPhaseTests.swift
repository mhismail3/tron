import XCTest
@testable import TronMobile

final class AgentPhaseTests: XCTestCase {

    // MARK: - Enum Value Tests

    func testIdleIsDefault() {
        let phase = AgentPhase.idle
        XCTAssertEqual(phase, .idle)
    }

    func testAllCasesExist() {
        let cases: [AgentPhase] = [.idle, .processing, .postProcessing]
        XCTAssertEqual(cases.count, 3)
    }

    // MARK: - Computed Property Tests

    func testIsProcessingTrueOnlyWhenProcessing() {
        XCTAssertFalse(AgentPhase.idle.isProcessing)
        XCTAssertTrue(AgentPhase.processing.isProcessing)
        XCTAssertFalse(AgentPhase.postProcessing.isProcessing)
    }

    func testIsPostProcessingTrueOnlyWhenPostProcessing() {
        XCTAssertFalse(AgentPhase.idle.isPostProcessing)
        XCTAssertFalse(AgentPhase.processing.isPostProcessing)
        XCTAssertTrue(AgentPhase.postProcessing.isPostProcessing)
    }

    func testIsIdleTrueOnlyWhenIdle() {
        XCTAssertTrue(AgentPhase.idle.isIdle)
        XCTAssertFalse(AgentPhase.processing.isIdle)
        XCTAssertFalse(AgentPhase.postProcessing.isIdle)
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        XCTAssertEqual(AgentPhase.idle, AgentPhase.idle)
        XCTAssertEqual(AgentPhase.processing, AgentPhase.processing)
        XCTAssertEqual(AgentPhase.postProcessing, AgentPhase.postProcessing)
        XCTAssertNotEqual(AgentPhase.idle, AgentPhase.processing)
        XCTAssertNotEqual(AgentPhase.processing, AgentPhase.postProcessing)
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
