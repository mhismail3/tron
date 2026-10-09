import XCTest
import Observation
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes from #420's status-owner slice: malformed protocol data,
/// stale profile/connection/read and surface leases, capability loss, background
/// retirement, unobserved projection replacement, and refresh cadence.
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

    func testCapabilityOffCannotBeginStatusRead() throws {
        let (owner, coordinator, token) = mountedOwner()
        XCTAssertNil(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: false, token: token, coordinator: coordinator))
        XCTAssertNil(owner.status)
    }

    func testStatusPublicationNotifiesObservationConsumers() async throws {
        let (owner, coordinator, token) = mountedOwner()
        let fence = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: true, token: token, coordinator: coordinator))
        let value = try decodeStatus()
        let changed = expectation(description: "status observation invalidated")
        withObservationTracking {
            _ = owner.status
        } onChange: {
            changed.fulfill()
        }
        XCTAssertTrue(owner.publish(value, for: fence))
        await fulfillment(of: [changed], timeout: 1)
    }

    func testOlderProfileAndReadGenerationCannotPublish() throws {
        let (owner, coordinator, token) = mountedOwner()
        let first = try XCTUnwrap(owner.beginRead(profileID: "p1", connectionID: "c1", capabilityEnabled: true, token: token, coordinator: coordinator))
        let second = try XCTUnwrap(owner.beginRead(profileID: "p1", connectionID: "c1", capabilityEnabled: true, token: token, coordinator: coordinator))
        let value = try decodeStatus()
        XCTAssertFalse(owner.publish(value, for: first), "a superseded read for the same profile/connection cannot publish")
        XCTAssertTrue(owner.publish(value, for: second))
        let current = try XCTUnwrap(owner.beginRead(profileID: "p2", connectionID: "c2", capabilityEnabled: true, token: token, coordinator: coordinator))
        XCTAssertFalse(owner.publish(value, for: second))
        XCTAssertTrue(owner.publish(value, for: current))
    }

    func testConnectionRetirementClearsOldStatusAndFreshAdmissionCanPublish() throws {
        let (owner, coordinator, token) = mountedOwner()
        let old = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "old", capabilityEnabled: true, token: token, coordinator: coordinator))
        let value = try decodeStatus()
        XCTAssertTrue(owner.publish(value, for: old))
        owner.connectionRetired()
        XCTAssertNil(owner.status)
        owner.connectionAvailable(profileID: "p", connectionID: "new", capabilityEnabled: true)
        let replacement = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "new", capabilityEnabled: true, token: token, coordinator: coordinator))
        XCTAssertFalse(owner.publish(value, for: old))
        XCTAssertTrue(owner.publish(value, for: replacement))
    }

    func testDelayedRetirementOfPreviousSurfaceCannotRetireReplacement() throws {
        let (owner, coordinatorA, tokenA) = mountedOwner(id: "home-dashboard")
        let old = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: true, token: tokenA, coordinator: coordinatorA))
        let value = try decodeStatus()
        XCTAssertTrue(owner.publish(value, for: old))

        let coordinatorB = PresentationActivityCoordinator()
        let tokenB = PresentationSurfaceToken(id: "home-dashboard", generation: UUID())
        coordinatorB.register(tokenB, parent: nil)
        owner.mountSurface(token: tokenB, coordinator: coordinatorB)
        let current = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: true, token: tokenB, coordinator: coordinatorB))
        XCTAssertTrue(owner.publish(value, for: current))
        owner.retireSurface(tokenA)
        XCTAssertEqual(owner.surfaceToken, tokenB)
        XCTAssertEqual(owner.status, value)
    }

    func testCoordinatorRetirementWhileFetchSuspendedCannotPublish() async throws {
        let (owner, coordinator, token) = mountedOwner()
        let started = expectation(description: "status read started")
        let fetchReturned = expectation(description: "resumed fetch returned to owner")
        var continuation: CheckedContinuation<HomeStatusDTO, Error>?
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true) { _ in
            let value = try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
            fetchReturned.fulfill()
            return value
        }
        await fulfillment(of: [started], timeout: 1)
        coordinator.retire(token)
        owner.presentationActivityChanged(for: token)
        continuation?.resume(returning: try decodeStatus())
        // Fetch completion and publication run on MainActor without another await;
        // once this waiter resumes, the owner has processed the returned value.
        await fulfillment(of: [fetchReturned], timeout: 1)
        XCTAssertNil(owner.status)
        owner.retireSurface(token)
    }

    func testCoordinatorRetirementWithoutActivityCallbackFencesCompletedFetch() async throws {
        let (owner, coordinator, token) = mountedOwner()
        let started = expectation(description: "status read started")
        let fetchReturned = expectation(description: "resumed fetch returned to owner")
        var continuation: CheckedContinuation<HomeStatusDTO, Error>?
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true) { _ in
            let value = try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
            fetchReturned.fulfill()
            return value
        }
        await fulfillment(of: [started], timeout: 1)
        coordinator.retire(token)
        continuation?.resume(returning: try decodeStatus())
        await fulfillment(of: [fetchReturned], timeout: 1)
        XCTAssertNil(owner.status)
        owner.retireSurface(token)
    }

    func testBackgroundedSurfaceRetiresItsPendingStatusRead() throws {
        let (owner, coordinator, token) = mountedOwner()
        let fence = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: true, token: token, coordinator: coordinator))
        let value = try decodeStatus()
        XCTAssertTrue(owner.publish(value, for: fence))
        owner.suspendForBackground()
        XCTAssertNil(owner.status)
        XCTAssertFalse(owner.publish(value, for: fence))
    }

    func testRejectsOversizedStatusProjection() {
        let gaps = Array(repeating: "gap", count: 129).map { "\"\($0)\"" }.joined(separator: ",")
        let oversized = validStatus.replacingOccurrences(of: "\"gaps\":[]", with: "\"gaps\":[\(gaps)]")
        XCTAssertThrowsError(try HomeStatusDTO.decode(JSONValue.parse(Data(oversized.utf8))))
    }

    func testMountedFallbackRefreshesAtFiveSecondCadence() async throws {
        let (owner, coordinator, _) = mountedOwner()
        let initial = expectation(description: "mounted initial refresh")
        let fallback = expectation(description: "five-second mounted fallback")
        var fetchCount = 0
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true) { [coordinator] _ in
            _ = coordinator
            fetchCount += 1
            if fetchCount == 1 { initial.fulfill() }
            if fetchCount == 2 { fallback.fulfill() }
            return try self.decodeStatus()
        }
        await fulfillment(of: [initial], timeout: 1)
        try await Task.sleep(for: .milliseconds(4_800))
        XCTAssertEqual(fetchCount, 1)
        await fulfillment(of: [fallback], timeout: 1.5)
        if let token = owner.surfaceToken { owner.retireSurface(token) }
    }

    func testMountedStatusRefreshesImmediatelyOnInvalidation() async throws {
        let (owner, coordinator, _) = mountedOwner()
        let initial = expectation(description: "mounted initial refresh")
        let invalidated = expectation(description: "immediate invalidation refresh")
        var fetchCount = 0
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true) { [coordinator] _ in
            _ = coordinator
            fetchCount += 1
            if fetchCount == 1 { initial.fulfill() }
            if fetchCount == 2 { invalidated.fulfill() }
            return try self.decodeStatus()
        }
        await fulfillment(of: [initial], timeout: 1)
        await owner.invalidateMounted()
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertNotNil(owner.status)
        if let token = owner.surfaceToken { owner.retireSurface(token) }
    }

    private func mountedOwner(id: String = "home") -> (HomeStatusPresentationOwner, PresentationActivityCoordinator, PresentationSurfaceToken) {
        let owner = HomeStatusPresentationOwner()
        let coordinator = PresentationActivityCoordinator()
        let token = PresentationSurfaceToken(id: id, generation: UUID())
        coordinator.register(token, parent: nil)
        owner.mountSurface(token: token, coordinator: coordinator)
        return (owner, coordinator, token)
    }

    private func decodeStatus() throws -> HomeStatusDTO {
        try HomeStatusDTO.decode(JSONValue.parse(Data(validStatus.utf8)))
    }
}

private extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
