import Foundation
import XCTest
@testable import TronComputerUseQualification

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; values.append(data) }
    var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class QualificationLifetimeTests: XCTestCase {
    func testDeadlineUsesLatestReceiptAndHasOneTerminalWinner() {
        let reports = Reports()
        let deadline = QualificationDeadline(seconds: 3_600, report: Data("initial".utf8)) { reports.append($0) }
        deadline.update(Data("uncertain-target".utf8))
        deadline.fire()
        deadline.update(Data("must-not-replace".utf8))
        deadline.fire()
        XCTAssertFalse(deadline.disarm())
        XCTAssertEqual(reports.snapshot, [Data("uncertain-target".utf8)])
    }

    func testNormalTerminalClaimPreventsLateDeadlineReport() {
        let reports = Reports()
        let deadline = QualificationDeadline(seconds: 3_600, report: Data()) { reports.append($0) }
        XCTAssertTrue(deadline.disarm())
        deadline.fire()
        XCTAssertTrue(reports.snapshot.isEmpty)
    }

    func testDeadlineFiresWithoutMainActorProgress() {
        let fired = DispatchSemaphore(value: 0)
        let reports = Reports()
        let deadline = QualificationDeadline(seconds: 0.02, report: Data("uncertain".utf8)) {
            reports.append($0)
            fired.signal()
        }
        // Deliberately block this actor; the safety timer must not hop onto it.
        XCTAssertEqual(fired.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(reports.snapshot, [Data("uncertain".utf8)])
        XCTAssertFalse(deadline.disarm())
    }

    func testBackgroundOrderAcceptsOnlyAnUnchangedDesktopWithFixtureBehind() {
        XCTAssertTrue(BackgroundWindowOrder.preserves([1, 2], current: [1, 2, 9], fixture: 9))
        // Outcome controls: raising, reordering, missing, duplicate and new
        // unrelated windows must all invalidate the observation.
        let rejected: [[UInt32]] = [[9, 1, 2], [2, 1, 9], [1, 9], [1, 2, 9, 9], [3, 1, 2, 9]]
        for order in rejected {
            XCTAssertFalse(BackgroundWindowOrder.preserves([1, 2], current: order, fixture: 9))
        }
    }
}
