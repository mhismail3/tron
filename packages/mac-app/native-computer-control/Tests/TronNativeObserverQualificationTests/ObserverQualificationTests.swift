import CoreGraphics
import XCTest
@testable import TronComputerControl
@testable import TronNativeObserverQualification

/// Offline data tests only: never call ObserverQualificationLifecycle.run or the
/// executable's observe mode. Native lifecycle behavior has a separate manual gate.
final class ObserverQualificationTests: XCTestCase {
    func testInvocationParsing() {
        for args in [[], ["--help"], ["-h"]] {
            XCTAssertEqual(ObserverQualificationInvocation.parse(args), .help)
        }
        XCTAssertEqual(ObserverQualificationInvocation.parse(["--observe"]), .observe(.defaults))
        XCTAssertEqual(ObserverQualificationInvocation.parse(["--observe-self-process"]),
                       .observe(.init(deadlineMilliseconds: 5_000, scope: .selfProcess)))
        XCTAssertEqual(ObserverQualificationInvocation.parse(["--observe", "--deadline-ms", "100"]),
                       .observe(.init(deadlineMilliseconds: 100)))
        for args in [["--invalid"], ["--observe", "--deadline-ms"], ["--observe", "--deadline-ms", "0"],
                     ["--observe", "--deadline-ms", "300001"], ["--observe", "--deadline-ms", "NaN"],
                     ["--observe", "--deadline-ms", "1", "--deadline-ms", "2"], ["--observe", "--max-events", "1"]] {
            guard case .invalid = ObserverQualificationInvocation.parse(args) else { return XCTFail("Invalid args admitted: \(args)") }
        }
    }

    func testValidReportRequiresOneExactObservedAndRetiredTap() throws {
        let report = report()
        XCTAssertTrue(report.validationErrors().isEmpty)
        XCTAssertTrue(report.passed)
        for changes: [String: Any] in [
            ["stopJoined": false], ["requestedEventsOfInterest": 1], ["callbackActivityCount": 2],
            ["inventoryAfterStart": []], ["newlyOwnedTapIDs": []], ["newlyOwnedTapIDs": [11, 11]],
            ["inventoryError": "unavailable"], ["processIdentifier": 12],
            ["inventoryAfterStop": [try object(tap(id: 11))]]
        ] {
            let invalid = try replacing(report, changes)
            XCTAssertFalse(invalid.validationErrors().isEmpty, "Accepted \(changes)")
            XCTAssertFalse(invalid.passed)
        }
    }

    func testUnavailableAndCancelledReportsCannotPassQualification() throws {
        for changes: [String: Any] in [["deadlineTriggered": true], ["cancellationObserved": true]] {
            let cancelled = try replacing(report(), changes)
            XCTAssertTrue(cancelled.validationErrors().isEmpty)
            XCTAssertFalse(cancelled.passed)
        }
        let unavailable = try replacing(report(), [
            "availability": ["available": false, "reason": "listen permission unavailable"],
            "inventoryAfterStart": [], "newlyOwnedTapIDs": []
        ])
        XCTAssertTrue(unavailable.validationErrors().isEmpty)
        XCTAssertFalse(unavailable.passed, "An empty retired set must not qualify a denied observer")
    }

    func testOwnedTapMaskModeScopeAndEnabledStateAreRequired() throws {
        let baseline = report()
        for fields: [String: Any] in [["eventsOfInterest": 1], ["tapPointRawValue": 2],
                                    ["optionsRawValue": 0], ["processBeingTapped": 7], ["enabled": false]] {
            var wrong = try object(tap(id: 11))
            wrong.merge(fields) { _, new in new }
            let report = try replacing(baseline, ["inventoryAfterStart": [wrong]])
            XCTAssertFalse(report.passed, "Accepted owned tap metadata \(fields)")
        }
    }

    func testProcessReportRequiresItsOwnPIDAndCannotAcceptASessionTap() throws {
        let baseline = report()
        XCTAssertFalse(try replacing(baseline, ["scope": "selfProcess"]).passed)
        var processTap = try object(tap(id: 11))
        processTap["processBeingTapped"] = 42
        let process = try replacing(baseline, ["scope": "selfProcess", "inventoryAfterStart": [processTap]])
        XCTAssertTrue(process.passed)
        processTap["processBeingTapped"] = 43
        XCTAssertFalse(try replacing(process, ["inventoryAfterStart": [processTap]]).passed)
    }

    func testUnrelatedBaselineTapIsPreservedNotMisidentifiedAsOwned() throws {
        let before = try object(tap(id: 10))
        let own = try object(tap(id: 11))
        let report = try replacing(report(), ["inventoryBefore": [before],
            "inventoryAfterStart": [before, own], "inventoryAfterStop": [before]])
        XCTAssertTrue(report.passed)
        XCTAssertFalse(try replacing(report, ["inventoryAfterStop": []]).passed)
    }

    private func report() -> ObserverQualificationReport {
        .init(schema: "tron.native-observer-qualification.v2", processIdentifier: 42, scope: .session,
              deadlineMilliseconds: 5_000, requestedEventsOfInterest: NativeEventObserver.requiredEventsOfInterest,
              inventoryBefore: [], availability: .init(available: true, generationID: UUID().uuidString,
                                                        generationNumber: 1, reason: nil),
              inventoryAfterStart: [tap(id: 11)], inventoryAfterStop: [], newlyOwnedTapIDs: [11],
              stopJoined: true, deadlineTriggered: false, cancellationObserved: false,
              callbackActivityCount: 0, inventoryError: nil)
    }

    private func tap(id: UInt32) -> NativeEventTapInventoryEntry {
        .init(eventTapID: id, tappingProcess: 42, processBeingTapped: 0,
              tapPointRawValue: Int32(CGEventTapLocation.cgSessionEventTap.rawValue),
              optionsRawValue: UInt32(CGEventTapOptions.listenOnly.rawValue),
              eventsOfInterest: NativeEventObserver.requiredEventsOfInterest, enabled: true)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func replacing(_ report: ObserverQualificationReport, _ changes: [String: Any]) throws -> ObserverQualificationReport {
        var value = try object(report)
        value.merge(changes) { _, new in new }
        return try JSONDecoder().decode(ObserverQualificationReport.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
