import XCTest
@testable import TronMobile

@MainActor
final class SessionLoadDiagnosticsTests: XCTestCase {
    func testInjectedClockProducesDeterministicPhaseEvidence() {
        var now = 10.0
        var entries: [String] = []
        let diagnostics = SessionLoadDiagnostics(
            clock: .init(now: { now }),
            log: { entries.append($0) }
        )

        now = 10.002
        diagnostics.recordShellPresented()
        now = 10.005
        diagnostics.recordCache(hit: true, eventCount: 40, messageCount: 12)
        now = 10.018
        diagnostics.recordAuthoritative(eventCount: 45, messageCount: 14)
        now = 10.020
        diagnostics.recordInteractive()

        XCTAssertEqual(diagnostics.snapshot.shellMs, 2)
        XCTAssertEqual(diagnostics.snapshot.cacheMs, 5)
        XCTAssertEqual(diagnostics.snapshot.cacheHit, true)
        XCTAssertEqual(diagnostics.snapshot.cachedEventCount, 40)
        XCTAssertEqual(diagnostics.snapshot.cachedMessageCount, 12)
        XCTAssertEqual(diagnostics.snapshot.authoritativeMs, 18)
        XCTAssertEqual(diagnostics.snapshot.authoritativeEventCount, 45)
        XCTAssertEqual(diagnostics.snapshot.authoritativeMessageCount, 14)
        XCTAssertEqual(diagnostics.snapshot.interactiveMs, 20)
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("[SESSION_LOAD]") })
    }

    func testDuplicatePresentationSignalsRemainSingleShot() {
        var now = 0.0
        let diagnostics = SessionLoadDiagnostics(clock: .init(now: { now }), log: { _ in })
        now = 0.001
        diagnostics.recordShellPresented()
        diagnostics.recordCache(hit: false, eventCount: 0, messageCount: 0)
        diagnostics.recordInteractive()

        now = 1.0
        diagnostics.recordShellPresented()
        diagnostics.recordCache(hit: true, eventCount: 1, messageCount: 1)
        diagnostics.recordInteractive()

        XCTAssertEqual(diagnostics.snapshot.shellMs, 1)
        XCTAssertEqual(diagnostics.snapshot.cacheHit, false)
        XCTAssertEqual(diagnostics.snapshot.interactiveMs, 1)
    }
}
