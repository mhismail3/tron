import XCTest
@testable import TronMobile

final class ProtocolConstantsTests: XCTestCase {

    // MARK: - CompactionReason Tests

    func testCompactionReasonThresholdExceededRawValue() {
        XCTAssertEqual(CompactionReason.thresholdExceeded.rawValue, "threshold_exceeded")
    }

    func testCompactionReasonManualRawValue() {
        XCTAssertEqual(CompactionReason.manual.rawValue, "manual")
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
        XCTAssertEqual(CompactionReason.thresholdExceeded.detailDisplayText, "Threshold")
        XCTAssertEqual(CompactionReason.manual.detailDisplayText, "Manual")
    }

}
