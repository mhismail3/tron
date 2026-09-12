import XCTest
@testable import TronMobile

final class DiagnosticCaptureTests: XCTestCase {
    func testDisabledCaptureCollectsNothing() {
        let capture = DiagnosticCaptureCoordinator()
        capture.recordCausal(name: "session.open", outcome: "success", durationMilliseconds: 4)
        XCTAssertEqual(capture.state, .idle)
        XCTAssertTrue(capture.report.events.isEmpty)
    }

    func testStartedCaptureFreezesOperationAndRPCEvidence() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        let interval = try! XCTUnwrap(capture.beginInterval())
        capture.recordInterval(interval.0, operation: .sessionOpen, started: interval.1, result: .success, metrics: .init(itemCount: 3))
        capture.recordRPC(method: "session.list", requestID: "opaque-id", requestStartedAt: interval.1, outcome: "success", code: nil, durationMilliseconds: 23, profileID: "profile", connectionID: 7)
        let report = try! XCTUnwrap(capture.stop())

        XCTAssertEqual(report.events.count, 2)
        XCTAssertEqual(report.events.map(\.name), ["sessionOpen", "session.list"])
        XCTAssertGreaterThanOrEqual(report.events[0].durationMilliseconds ?? -1, 0)
        XCTAssertTrue(report.text.contains("operation=sessionOpen count=1"))
        XCTAssertTrue(report.text.contains("operation=session.list count=1"))
        XCTAssertTrue(report.text.contains("requestID=opaque-id"), "opaque request IDs correlate repeated calls without payloads")
    }

    func testCaptureBoundsEventsAndStartsFreshReport() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        for _ in 0..<(DiagnosticCaptureCoordinator.maximumEvents + 25) {
            capture.recordCausal(name: "chatProjection", outcome: "success", durationMilliseconds: 1)
        }
        let report = try! XCTUnwrap(capture.stop())
        XCTAssertEqual(report.events.count, DiagnosticCaptureCoordinator.maximumEvents)
        XCTAssertGreaterThan(report.droppedEvents, 0)
        XCTAssertTrue(report.incomplete)

        XCTAssertTrue(capture.start(duration: .seconds(30)))
        XCTAssertTrue(capture.report.events.isEmpty)
        XCTAssertEqual(capture.stop()?.events.count, 0)
    }

    func testExportTextStaysWithinByteBoundWithMaximumFields() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30), profileID: String(repeating: "p", count: 500)))
        for _ in 0..<DiagnosticCaptureCoordinator.maximumEvents {
            capture.recordCausal(
                name: String(repeating: "n", count: 500),
                outcome: String(repeating: "o", count: 500),
                durationMilliseconds: Int.max,
                count: Int.max,
                profileID: String(repeating: "p", count: 500),
                connectionID: Int.max,
                lifecycleGeneration: Int.max,
                requestID: String(repeating: "r", count: 500)
            )
        }
        let report = try! XCTUnwrap(capture.stop())

        XCTAssertLessThanOrEqual(report.text.utf8.count, DiagnosticCaptureCoordinator.maximumBytes)
        XCTAssertTrue(report.incomplete)
    }

    func testRetiredCaptureCannotReceiveLateOperation() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        _ = capture.stop(reason: "background")
        capture.recordCausal(name: "sessionSync", outcome: "success", durationMilliseconds: 8)
        XCTAssertTrue(capture.report.events.isEmpty)
    }

    func testLateIntervalFromStoppedCaptureCannotEnterSuccessor() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        let interval = try! XCTUnwrap(capture.beginInterval())
        _ = capture.stop(reason: "user")
        XCTAssertTrue(capture.start(duration: .seconds(30)))

        capture.recordInterval(
            interval.0, operation: .sessionOpen, started: interval.1,
            result: .success, metrics: .none
        )

        XCTAssertTrue(capture.report.events.isEmpty)
        XCTAssertEqual(capture.stop()?.events.count, 0)
    }

    func testLateRPCFromBeforeCaptureCannotEnterSuccessor() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        let interval = try! XCTUnwrap(capture.beginInterval())
        _ = capture.stop(reason: "user")
        XCTAssertTrue(capture.start(duration: .seconds(30)))

        capture.recordRPC(
            method: "session.list", requestID: "old-request", requestStartedAt: interval.1,
            outcome: "success", code: nil, durationMilliseconds: 23,
            profileID: "old-profile", connectionID: 1
        )

        XCTAssertTrue(capture.report.events.isEmpty)
        XCTAssertEqual(capture.stop()?.events.count, 0)
    }

    func testPendingIntervalsAreBoundedAndCountedAsDropped() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        for _ in 0..<DiagnosticCaptureCoordinator.maximumPendingIntervals {
            XCTAssertNotNil(capture.beginInterval())
        }
        XCTAssertNil(capture.beginInterval())

        XCTAssertEqual(capture.stop()?.droppedEvents, 1)
    }

    func testCanceledDeadlineCannotStopSuccessorCapture() async throws {
        let manual = ManualClock()
        let capture = DiagnosticCaptureCoordinator(clock: manual.clock)
        XCTAssertTrue(capture.start(duration: .seconds(1)))
        try await manual.waitUntilSleeping(count: 1, duration: .seconds(1))

        XCTAssertTrue(capture.start(duration: .seconds(30)))
        manual.advance(by: .seconds(1))
        await Task.yield()

        if case .capturing = capture.state {
            // The canceled deadline belongs to the retired capture. The new
            // capture must remain active even when the old timer was due.
        } else {
            XCTFail("successor capture was stopped by the retired deadline")
        }
        _ = capture.stop()
    }
}
