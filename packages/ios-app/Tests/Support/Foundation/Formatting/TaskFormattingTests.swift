import XCTest
@testable import TronMobile

final class TaskFormattingTests: XCTestCase {

    // MARK: - statusColor

    func test_statusColor_completed_returnsTronSuccess() {
        XCTAssertEqual(TaskFormatting.statusColor("completed"), .tronSuccess)
    }

    func test_statusColor_inProgress_returnsTronTeal() {
        XCTAssertEqual(TaskFormatting.statusColor("in_progress"), .tronTeal)
    }

    func test_statusColor_cancelled_returnsTronError() {
        XCTAssertEqual(TaskFormatting.statusColor("cancelled"), .tronError)
    }

    func test_statusColor_stale_returnsTronAmber() {
        XCTAssertEqual(TaskFormatting.statusColor("stale"), .tronAmber)
    }

    func test_statusColor_pending_returnsTronSlate() {
        XCTAssertEqual(TaskFormatting.statusColor("pending"), .tronSlate)
    }

    func test_statusColor_unknown_returnsTronSlate() {
        XCTAssertEqual(TaskFormatting.statusColor("something_else"), .tronSlate)
    }

    // MARK: - statusMark

    func test_statusMark_completed_returnsX() {
        XCTAssertEqual(TaskFormatting.statusMark("completed"), "x")
    }

    func test_statusMark_inProgress_returnsAngle() {
        XCTAssertEqual(TaskFormatting.statusMark("in_progress"), ">")
    }

    func test_statusMark_cancelled_returnsDash() {
        XCTAssertEqual(TaskFormatting.statusMark("cancelled"), "-")
    }

    func test_statusMark_stale_returnsQuestion() {
        XCTAssertEqual(TaskFormatting.statusMark("stale"), "?")
    }

    func test_statusMark_unknown_returnsSpace() {
        XCTAssertEqual(TaskFormatting.statusMark("something"), " ")
    }
}
