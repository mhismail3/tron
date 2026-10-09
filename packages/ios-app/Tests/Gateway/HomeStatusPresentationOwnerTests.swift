import XCTest
import Observation
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes from #420's status-owner slice: malformed protocol data,
/// stale profile/connection/read and surface leases, capability loss, background
/// retirement, unobserved projection replacement, and refresh cadence.
@MainActor
final class HomeStatusPresentationOwnerTests: XCTestCase {
    /// The owner holds its presentation coordinator weakly, so each mounted
    /// coordinator stays alive for the life of its test case.
    private var mountedCoordinators: [PresentationActivityCoordinator] = []
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
        owner.mountSurface(token: tokenB, coordinator: coordinatorB, fetch: { _ in throw CancellationError() })
        let current = try XCTUnwrap(owner.beginRead(profileID: "p", connectionID: "c", capabilityEnabled: true, token: tokenB, coordinator: coordinatorB))
        XCTAssertTrue(owner.publish(value, for: current))
        owner.retireSurface(tokenA)
        XCTAssertEqual(owner.surfaceToken, tokenB)
        XCTAssertEqual(owner.status, value)
    }

    func testCoordinatorRetirementWhileFetchSuspendedCannotPublish() async throws {
        let started = expectation(description: "status read started")
        let fetchReturned = expectation(description: "resumed fetch returned to owner")
        var continuation: CheckedContinuation<HomeStatusDTO, Error>?
        let (owner, coordinator, token) = mountedOwner { _ in
            let value = try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
            fetchReturned.fulfill()
            return value
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
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
        let started = expectation(description: "status read started")
        let fetchReturned = expectation(description: "resumed fetch returned to owner")
        var continuation: CheckedContinuation<HomeStatusDTO, Error>?
        let (owner, coordinator, token) = mountedOwner { _ in
            let value = try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
            fetchReturned.fulfill()
            return value
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
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

    /// The dashboard mounts before pairing, so the surface has no profile yet.
    /// Pairing then configures the profile; the read must still run, because the
    /// surface, not the profile, owns the fetch.
    func testSurfaceMountedBeforePairingReadsOnceProfileIsConnected() async throws {
        let fetched = expectation(description: "status read after pairing")
        var fetchCount = 0
        let (owner, _, token) = mountedOwner { _ in
            fetchCount += 1
            fetched.fulfill()
            return try self.decodeStatus()
        }
        owner.connectionAvailable(profileID: "paired", connectionID: "c", capabilityEnabled: true)
        await fulfillment(of: [fetched], timeout: 1)
        XCTAssertEqual(fetchCount, 1)
        owner.retireSurface(token)
    }

    /// A profile transition forgets the capability; a dropped connection keeps it,
    /// so reconnecting to the same profile does not flicker the Home row.
    func testProfileRetirementForgetsCapabilityButConnectionLossKeepsIt() {
        let (owner, _, token) = mountedOwner()
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        XCTAssertTrue(owner.isCapabilityEnabled)
        owner.connectionRetired()
        XCTAssertTrue(owner.isCapabilityEnabled)
        owner.profileRetired()
        XCTAssertFalse(owner.isCapabilityEnabled)
        owner.retireSurface(token)
    }

    /// A Gateway status this client cannot admit is a typed unavailable state,
    /// not a row that keeps saying it is loading, and the next valid read clears it.
    func testUndecodableStatusIsUnavailableUntilAValidReadPublishes() async throws {
        var admitsStatus = false
        let (owner, _, token) = mountedOwner { _ in
            if !admitsStatus {
                return try HomeStatusDTO.decode(JSONValue.parse(Data(#"{"phase":"future-phase"}"#.utf8)))
            }
            return try self.decodeStatus()
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        await owner.invalidateMounted()
        XCTAssertNil(owner.status)
        XCTAssertTrue(owner.isStatusUnavailable)
        admitsStatus = true
        await owner.invalidateMounted()
        XCTAssertNotNil(owner.status)
        XCTAssertFalse(owner.isStatusUnavailable)
        owner.retireSurface(token)
    }

    func testRejectsOversizedStatusProjection() {
        let gaps = Array(repeating: "gap", count: 129).map { "\"\($0)\"" }.joined(separator: ",")
        let oversized = validStatus.replacingOccurrences(of: "\"gaps\":[]", with: "\"gaps\":[\(gaps)]")
        XCTAssertThrowsError(try HomeStatusDTO.decode(JSONValue.parse(Data(oversized.utf8))))
    }

    func testMountedFallbackRefreshesAtFiveSecondCadence() async throws {
        let initial = expectation(description: "mounted initial refresh")
        let fallback = expectation(description: "five-second mounted fallback")
        var fetchCount = 0
        let (owner, _, _) = mountedOwner { _ in
            fetchCount += 1
            if fetchCount == 1 { initial.fulfill() }
            if fetchCount == 2 { fallback.fulfill() }
            return try self.decodeStatus()
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        await fulfillment(of: [initial], timeout: 1)
        try await Task.sleep(for: .milliseconds(4_800))
        XCTAssertEqual(fetchCount, 1)
        await fulfillment(of: [fallback], timeout: 1.5)
        if let token = owner.surfaceToken { owner.retireSurface(token) }
    }

    func testMountedStatusRefreshesImmediatelyOnInvalidation() async throws {
        let initial = expectation(description: "mounted initial refresh")
        let invalidated = expectation(description: "immediate invalidation refresh")
        var fetchCount = 0
        let (owner, _, _) = mountedOwner { _ in
            fetchCount += 1
            if fetchCount == 1 { initial.fulfill() }
            if fetchCount == 2 { invalidated.fulfill() }
            return try self.decodeStatus()
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        await fulfillment(of: [initial], timeout: 1)
        await owner.invalidateMounted()
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertNotNil(owner.status)
        if let token = owner.surfaceToken { owner.retireSurface(token) }
    }

    private func mountedOwner(
        id: String = "home",
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO = { _ in throw CancellationError() }
    ) -> (HomeStatusPresentationOwner, PresentationActivityCoordinator, PresentationSurfaceToken) {
        let owner = HomeStatusPresentationOwner()
        let coordinator = PresentationActivityCoordinator()
        let token = PresentationSurfaceToken(id: id, generation: UUID())
        coordinator.register(token, parent: nil)
        mountedCoordinators.append(coordinator)
        owner.mountSurface(token: token, coordinator: coordinator, fetch: fetch)
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
