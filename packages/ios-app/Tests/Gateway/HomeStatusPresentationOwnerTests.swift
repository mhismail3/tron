import XCTest
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes from #420's approved status-owner slice: malformed status must
/// not be partially accepted; an old profile/connection/read or retired surface
/// must not publish; unsupported capability must never issue a read; reconnect
/// must replace the old projection; mounted refresh stays bounded to 5 seconds.
@MainActor
final class HomeStatusPresentationOwnerTests: XCTestCase {
    private let validStatus = #"{"phase":"ready","activation":{"available":false},"readiness":{"ready":true,"gaps":[]},"recovery":{"action":"none"},"available":true,"enabled":true,"live":false,"sessionPresent":true,"memory":{"configured":true,"open":true}}"#

    func testDecodesTypedHomeStatusAndRequiresAllProtocolSections() throws {
        let status = try HomeStatusDTO.decode(JSONValue.parse(Data(validStatus.utf8)))
        XCTAssertEqual(status.phase, .ready)
        XCTAssertEqual(status.activation.available, false)
        XCTAssertTrue(status.readiness.ready)
        XCTAssertEqual(status.recovery.action, .none)
        XCTAssertThrowsError(try HomeStatusDTO.decode(JSONValue.parse(Data(#"{"phase":"ready"}"#.utf8))))
    }

    func testRejectsUnknownPhaseAndMalformedActivationReadinessOrRecovery() {
        for replacement in [
            (#""phase":"ready""#, #""phase":"future-phase""#),
            (#""activation":{"available":false}"#, #""activation":{}"#),
            (#""readiness":{"ready":true,"gaps":[]}"#, #""readiness":{"ready":"yes","gaps":[]}"#),
            (#""recovery":{"action":"none"}"#, #""recovery":{"action":"guess"}"#),
        ] {
            let malformed = validStatus.replacingOccurrences(of: replacement.0, with: replacement.1)
            XCTAssertThrowsError(try HomeStatusDTO.decode(JSONValue.parse(Data(malformed.utf8))))
        }
    }

    func testCapabilityOffCannotBeginStatusRead() {
        let owner = HomeStatusPresentationOwner()
        XCTAssertNil(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: false, presentationActive: true))
        XCTAssertNil(owner.status)
    }

    func testOlderProfileAndReadGenerationCannotPublish() throws {
        let owner = HomeStatusPresentationOwner()
        let first = try XCTUnwrap(owner.beginRead(profileID: "p1", connectionID: "c1", capabilityEnabled: true, presentationActive: true))
        let second = try XCTUnwrap(owner.beginRead(profileID: "p1", connectionID: "c1", capabilityEnabled: true, presentationActive: true))
        let currentProfile = try XCTUnwrap(owner.beginRead(profileID: "p2", connectionID: "c2", capabilityEnabled: true, presentationActive: true))
        let value = try HomeStatusDTO.decode(JSONValue.parse(Data(validStatus.utf8)))
        XCTAssertFalse(owner.publish(value, for: first, currentProfileID: "p1", currentConnectionID: "c1", presentationActive: true))
        XCTAssertFalse(owner.publish(value, for: second, currentProfileID: "p2", currentConnectionID: "c2", presentationActive: true))
        XCTAssertTrue(owner.publish(value, for: currentProfile, currentProfileID: "p2", currentConnectionID: "c2", presentationActive: true))
    }

    func testRejectsOversizedStatusProjection() {
        let gaps = Array(repeating: "gap", count: 129).map { "\"\($0)\"" }.joined(separator: ",")
        let oversized = validStatus.replacingOccurrences(of: "\"gaps\":[]", with: "\"gaps\":[\(gaps)]")
        XCTAssertThrowsError(try HomeStatusDTO.decode(JSONValue.parse(Data(oversized.utf8))))
    }

    func testReconnectRetiresOldConnectionAndLifecycleRetiresSurface() throws {
        let owner = HomeStatusPresentationOwner()
        let old = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "old", capabilityEnabled: true, presentationActive: true))
        let replacement = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "new", capabilityEnabled: true, presentationActive: true))
        let value = try HomeStatusDTO.decode(JSONValue.parse(Data(validStatus.utf8)))
        XCTAssertFalse(owner.publish(value, for: old, currentProfileID: "p", currentConnectionID: "new", presentationActive: true))
        XCTAssertTrue(owner.publish(value, for: replacement, currentProfileID: "p", currentConnectionID: "new", presentationActive: true))
        owner.retireSurface()
        XCTAssertFalse(owner.publish(value, for: replacement, currentProfileID: "p", currentConnectionID: "new", presentationActive: true))
        XCTAssertNil(owner.status)
    }

    func testMountedFallbackCadenceIsNoMoreFrequentThanFiveSeconds() {
        XCTAssertTrue(HomeStatusPresentationOwner.shouldRefreshForInvalidation(isMounted: true, isForeground: true))
        XCTAssertFalse(HomeStatusPresentationOwner.shouldRefreshForInvalidation(isMounted: false, isForeground: true))
        XCTAssertFalse(HomeStatusPresentationOwner.shouldRefreshForInvalidation(isMounted: true, isForeground: false))
    }

    func testMountedFallbackRefreshesAtFiveSecondCadence() async throws {
        let owner = HomeStatusPresentationOwner()
        let initial = expectation(description: "mounted initial refresh")
        let fallback = expectation(description: "five-second mounted fallback")
        var fetchCount = 0
        owner.mountFallback(profileID: "p", connectionID: "c", capabilityEnabled: true, presentationActive: true) { _ in
            fetchCount += 1
            if fetchCount == 1 { initial.fulfill() }
            if fetchCount == 2 { fallback.fulfill() }
            return try HomeStatusDTO.decode(JSONValue.parse(Data(self.validStatus.utf8)))
        }
        await fulfillment(of: [initial], timeout: 1)
        try await Task.sleep(for: .milliseconds(4_800))
        XCTAssertEqual(fetchCount, 1)
        await fulfillment(of: [fallback], timeout: 1.5)
        owner.retireSurface()
    }

    func testMountedStatusRefreshesImmediatelyOnInvalidation() async throws {
        let owner = HomeStatusPresentationOwner()
        let initial = expectation(description: "mounted initial refresh")
        let invalidated = expectation(description: "immediate invalidation refresh")
        var fetchCount = 0
        owner.mountFallback(profileID: "p", connectionID: "c", capabilityEnabled: true, presentationActive: true) { _ in
            fetchCount += 1
            if fetchCount == 1 { initial.fulfill() }
            if fetchCount == 2 { invalidated.fulfill() }
            return try HomeStatusDTO.decode(JSONValue.parse(Data(self.validStatus.utf8)))
        }
        await fulfillment(of: [initial], timeout: 1)
        await owner.invalidateMounted(presentationActive: true)
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertNotNil(owner.status)
        owner.retireSurface()
    }
}

private extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
