import XCTest
@testable import TronMobile

final class ProtocolConstantsTests: XCTestCase {

    // MARK: - CompactionReason Tests

    func testCompactionReasonPreTurnGuardrailRawValue() {
        XCTAssertEqual(CompactionReason.preTurnGuardrail.rawValue, "pre_turn_guardrail")
    }

    func testCompactionReasonThresholdExceededRawValue() {
        XCTAssertEqual(CompactionReason.thresholdExceeded.rawValue, "threshold_exceeded")
    }

    func testCompactionReasonManualRawValue() {
        XCTAssertEqual(CompactionReason.manual.rawValue, "manual")
    }

    func testCompactionReasonPreTurnGuardrailDisplayText() {
        XCTAssertEqual(CompactionReason.preTurnGuardrail.displayText, "auto")
    }

    func testCompactionReasonThresholdExceededDisplayText() {
        XCTAssertEqual(CompactionReason.thresholdExceeded.displayText, "threshold")
    }

    func testCompactionReasonManualDisplayText() {
        XCTAssertEqual(CompactionReason.manual.displayText, "manual")
    }

    func testCompactionReasonUnknownValue() {
        let reason = CompactionReason(rawValue: "unknown_value")
        XCTAssertNil(reason)
    }

    func testCompactionReasonDetailDisplayText() {
        XCTAssertEqual(CompactionReason.preTurnGuardrail.detailDisplayText, "Auto")
        XCTAssertEqual(CompactionReason.thresholdExceeded.detailDisplayText, "Threshold")
        XCTAssertEqual(CompactionReason.manual.detailDisplayText, "Manual")
    }

    // MARK: - AgentProtocol Tests

    func testAskUserAnswerPrefix() {
        XCTAssertEqual(AgentProtocol.askUserAnswerPrefix, "[Answers to your questions]")
    }

    func testSubagentResultPrefix() {
        XCTAssertEqual(AgentProtocol.subagentResultPrefix, "[SUBAGENT RESULTS")
    }
}
