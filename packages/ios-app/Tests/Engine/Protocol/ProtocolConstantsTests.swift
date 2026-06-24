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

    func testCompactionReasonProgressSignalRawValue() {
        XCTAssertEqual(CompactionReason.progressSignal.rawValue, "progress_signal")
    }

    func testCompactionReasonThresholdExceededDisplayText() {
        XCTAssertEqual(CompactionReason.thresholdExceeded.displayText, "threshold")
    }

    func testCompactionReasonManualDisplayText() {
        XCTAssertEqual(CompactionReason.manual.displayText, "manual")
    }

    func testCompactionReasonProgressSignalDisplayText() {
        XCTAssertEqual(CompactionReason.progressSignal.displayText, "progress")
    }

    func testCompactionReasonUnknownValue() {
        let reason = CompactionReason(rawValue: "unknown_value")
        XCTAssertNil(reason)
    }

    func testCompactionReasonDetailDisplayText() {
        XCTAssertEqual(CompactionReason.thresholdExceeded.detailDisplayText, "Threshold")
        XCTAssertEqual(CompactionReason.progressSignal.detailDisplayText, "Progress Signal")
        XCTAssertEqual(CompactionReason.manual.detailDisplayText, "Manual")
    }

}
