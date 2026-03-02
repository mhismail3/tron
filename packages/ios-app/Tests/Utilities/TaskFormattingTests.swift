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

    func test_statusColor_backlog_returnsTronSlate() {
        XCTAssertEqual(TaskFormatting.statusColor("backlog"), .tronSlate)
    }

    func test_statusColor_paused_returnsTronAmber() {
        XCTAssertEqual(TaskFormatting.statusColor("paused"), .tronAmber)
    }

    func test_statusColor_archived_returnsTronSlate() {
        XCTAssertEqual(TaskFormatting.statusColor("archived"), .tronSlate)
    }

    func test_statusColor_active_returnsTronTeal() {
        XCTAssertEqual(TaskFormatting.statusColor("active"), .tronTeal)
    }

    func test_statusColor_pending_returnsTronSlate() {
        XCTAssertEqual(TaskFormatting.statusColor("pending"), .tronSlate)
    }

    func test_statusColor_unknown_returnsTronSlate() {
        XCTAssertEqual(TaskFormatting.statusColor("something_else"), .tronSlate)
    }

    // MARK: - priorityColor

    func test_priorityColor_critical_returnsTronError() {
        XCTAssertEqual(TaskFormatting.priorityColor("critical"), .tronError)
    }

    func test_priorityColor_bracketCritical_returnsTronError() {
        XCTAssertEqual(TaskFormatting.priorityColor("[critical]"), .tronError)
    }

    func test_priorityColor_high_returnsOrange() {
        XCTAssertEqual(TaskFormatting.priorityColor("high"), .orange)
    }

    func test_priorityColor_bracketHigh_returnsOrange() {
        XCTAssertEqual(TaskFormatting.priorityColor("[high]"), .orange)
    }

    func test_priorityColor_low_returnsTronTextMuted() {
        XCTAssertEqual(TaskFormatting.priorityColor("low"), .tronTextMuted)
    }

    func test_priorityColor_bracketLow_returnsTronTextMuted() {
        XCTAssertEqual(TaskFormatting.priorityColor("[low]"), .tronTextMuted)
    }

    func test_priorityColor_unknown_returnsTronTextSecondary() {
        XCTAssertEqual(TaskFormatting.priorityColor("medium"), .tronTextSecondary)
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

    func test_statusMark_backlog_returnsB() {
        XCTAssertEqual(TaskFormatting.statusMark("backlog"), "b")
    }

    func test_statusMark_unknown_returnsSpace() {
        XCTAssertEqual(TaskFormatting.statusMark("something"), " ")
    }
}
