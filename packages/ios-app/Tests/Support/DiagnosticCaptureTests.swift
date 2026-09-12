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
        capture.recordRPC(method: "session.list", requestID: "opaque-id", outcome: "success", code: nil, durationMilliseconds: 23, profileID: "profile", connectionID: 7)
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

    func testRetiredCaptureCannotReceiveLateOperation() {
        let capture = DiagnosticCaptureCoordinator()
        XCTAssertTrue(capture.start(duration: .seconds(30)))
        _ = capture.stop(reason: "background")
        capture.recordCausal(name: "sessionSync", outcome: "success", durationMilliseconds: 8)
        XCTAssertTrue(capture.report.events.isEmpty)
    }
}
