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

    /// Pairing configures the profile and the mounted surface reports itself
    /// active in the same main-actor turn, as one mount does. Those two starts
    /// are one mount and must start one read: a second read would cancel the
    /// first after it had already invoked the Gateway fetch.
    func testMountStartsOneReadWhenConfigurationAndActivityArriveTogether() async throws {
        var fetchCount = 0
        let (owner, coordinator, token) = mountedOwner { _ in
            fetchCount += 1
            try await Task.sleep(for: .seconds(60))
            return try self.decodeStatus()
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        owner.presentationActivityChanged(for: token)
        try await waitUntil { fetchCount >= 1 }
        // Bounded settle: let any redundant start reach its fetch before counting.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fetchCount, 1)
        owner.retireSurface(token)
        coordinator.retire(token)
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

    func testUnresolvedClaimReadsPerConnectionAndNeverPolls() async throws {
        let claimed = expectation(description: "claim read")
        let reconnected = expectation(description: "read after connection admission")
        var fetchCount = 0
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.home)) { _ in
            fetchCount += 1
            if fetchCount == 1 { claimed.fulfill() }
            if fetchCount == 2 { reconnected.fulfill() }
            throw URLError(.networkConnectionLost)
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        await fulfillment(of: [claimed], timeout: 1)
        try await Task.sleep(for: .milliseconds(5_300))
        XCTAssertEqual(fetchCount, 1, "a claim that has not published polls at no cadence")
        await owner.invalidateMounted()
        XCTAssertEqual(fetchCount, 1, "a claim that has not published is not refreshed by invalidation")
        owner.connectionAvailable(profileID: "p", connectionID: "next", capabilityEnabled: true)
        await fulfillment(of: [reconnected], timeout: 1)
        XCTAssertEqual(fetchCount, 2)
        owner.retireSurface(token)
        coordinator.retire(token)
    }

    func testMatchingClaimPromotesToMountedCadence() async throws {
        var fetchCount = 0
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.home)) { _ in
            fetchCount += 1
            return try self.decodeStatus(sessionID: "home-session")
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        try await waitUntil { owner.status != nil }
        XCTAssertEqual(owner.status?.sessionId, "home-session")
        XCTAssertEqual(fetchCount, 1, "publishing the claim takes no extra read")
        await owner.invalidateMounted()
        XCTAssertEqual(fetchCount, 2, "a promoted claim refreshes on invalidation")
        try await Task.sleep(for: .seconds(5.5))
        XCTAssertEqual(fetchCount, 3, "a promoted claim runs the five-second mounted fallback")
        owner.retireSurface(token)
        coordinator.retire(token)
    }

    /// Rollover: the reserved successor is `sessionId`, while the sealed
    /// predecessor is the only openable chapter. A chat opened on the predecessor
    /// is claimed by what it opens, so it keeps the status surface.
    func testClaimOnSealedPredecessorIsPromotedDuringRollover() async throws {
        var fetchCount = 0
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.home)) { _ in
            fetchCount += 1
            return try self.decodeStatus(sessionID: "successor-session", openSessionID: "predecessor-session")
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        try await waitUntil { owner.status != nil }
        XCTAssertEqual(owner.status?.openSessionId, "predecessor-session")
        XCTAssertEqual(fetchCount, 1)
        await owner.invalidateMounted()
        XCTAssertEqual(fetchCount, 2, "a claim on the openable predecessor is promoted and refreshes")
        owner.retireSurface(token)
        coordinator.retire(token)
    }

    /// An ordinary chat on the sealed predecessor is presented by its reserved
    /// `sessionId`, not the chapter it opens. Its probe is released at the first
    /// publication, so the rollover predecessor's status is never read again for it.
    func testOrdinaryProbeOnRolloverPredecessorReleasesOnFirstPublication() async throws {
        var fetchCount = 0
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.ordinary(sessionID: "predecessor-session"))) { _ in
            fetchCount += 1
            return try self.decodeStatus(sessionID: "successor-session", openSessionID: "predecessor-session")
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        try await waitUntil { owner.status != nil }
        XCTAssertEqual(owner.status?.openSessionId, "predecessor-session", "the released status stays for the dashboard")
        await owner.invalidateMounted()
        await owner.refreshMounted()
        XCTAssertEqual(fetchCount, 1, "an ordinary chat on the sealed predecessor is released, so it never refreshes")
        owner.retireSurface(token)
        coordinator.retire(token)
    }

    func testNonMatchingClaimReleasesEveryReadButKeepsStatus() async throws {
        var fetchCount = 0
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.ordinary(sessionID: "ordinary-session"))) { _ in
            fetchCount += 1
            return try self.decodeStatus(sessionID: "home-session")
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        try await waitUntil { owner.status != nil }
        XCTAssertEqual(owner.status?.sessionId, "home-session", "the released status stays for the dashboard")
        XCTAssertEqual(fetchCount, 1)

        await owner.invalidateMounted()
        await owner.invalidateMounted(sessionID: "home-session")
        await owner.refreshMounted()
        let cover = PresentationSurfaceToken(id: "cover", generation: UUID())
        coordinator.register(cover, parent: token)
        owner.presentationActivityChanged(for: token)
        coordinator.retire(cover)
        owner.presentationActivityChanged(for: token)
        XCTAssertEqual(owner.status?.sessionId, "home-session", "the released status stays for the dashboard")
        owner.connectionAvailable(profileID: "p", connectionID: "next", capabilityEnabled: true)
        try await Task.sleep(for: .seconds(5.5))
        XCTAssertEqual(fetchCount, 1, "a released claim reads on no invalidation, mutation, uncover, connection, or fallback")
        owner.retireSurface(token)
        coordinator.retire(token)
    }

    func testCoveredClaimReadRetriesOnceWhenSurfaceUncovers() async throws {
        var fetchCount = 0
        var gated: [CheckedContinuation<HomeStatusDTO, Error>] = []
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.home)) { _ in
            fetchCount += 1
            if fetchCount == 1 {
                return try await withCheckedThrowingContinuation { gated.append($0) }
            }
            return try self.decodeStatus(sessionID: "home-session")
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        try await waitUntil { fetchCount == 1 }
        let cover = PresentationSurfaceToken(id: "cover", generation: UUID())
        coordinator.register(cover, parent: token)
        owner.presentationActivityChanged(for: token)
        gated[0].resume(returning: try decodeStatus(sessionID: "home-session"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(owner.status, "a read discarded by the cover publishes nothing")

        coordinator.retire(cover)
        owner.presentationActivityChanged(for: token)
        try await waitUntil { owner.status != nil }
        XCTAssertEqual(fetchCount, 2, "the uncover retries the discarded claim read once")
        XCTAssertEqual(owner.status?.sessionId, "home-session")
        owner.retireSurface(token)
    }

    func testClaimCoverRetryRunsOnlyOncePerClaim() async throws {
        var fetchCount = 0
        var gated: [CheckedContinuation<HomeStatusDTO, Error>] = []
        let (owner, coordinator, token) = mountedOwner(cadence: .connectionOnly(.home)) { _ in
            fetchCount += 1
            if fetchCount <= 2 {
                return try await withCheckedThrowingContinuation { gated.append($0) }
            }
            return try self.decodeStatus(sessionID: "home-session")
        }
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true)
        try await waitUntil { fetchCount == 1 }
        let cover = PresentationSurfaceToken(id: "cover", generation: UUID())
        coordinator.register(cover, parent: token)
        owner.presentationActivityChanged(for: token)
        gated[0].resume(returning: try decodeStatus(sessionID: "home-session"))
        coordinator.retire(cover)
        owner.presentationActivityChanged(for: token)
        try await waitUntil { fetchCount == 2 }
        guard gated.count == 2 else {
            XCTFail("the first uncover must start exactly one retry read")
            return
        }

        let secondCover = PresentationSurfaceToken(id: "cover", generation: UUID())
        coordinator.register(secondCover, parent: token)
        owner.presentationActivityChanged(for: token)
        gated[1].resume(returning: try decodeStatus(sessionID: "home-session"))
        coordinator.retire(secondCover)
        owner.presentationActivityChanged(for: token)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fetchCount, 2, "a second cover of the same claim is not retried")
        XCTAssertNil(owner.status)
        owner.retireSurface(token)
        coordinator.retire(token)
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
        cadence: HomeStatusPresentationOwner.Cadence = .mounted,
        fetch: @escaping @MainActor (HomeStatusReadFence) async throws -> HomeStatusDTO = { _ in throw CancellationError() }
    ) -> (HomeStatusPresentationOwner, PresentationActivityCoordinator, PresentationSurfaceToken) {
        let owner = HomeStatusPresentationOwner()
        let coordinator = PresentationActivityCoordinator()
        let token = PresentationSurfaceToken(id: id, generation: UUID())
        coordinator.register(token, parent: nil)
        mountedCoordinators.append(coordinator)
        owner.mountSurface(token: token, coordinator: coordinator, cadence: cadence, fetch: fetch)
        return (owner, coordinator, token)
    }

    /// A status whose openable chapter is `openSessionID` (defaults to `sessionID`,
    /// the non-rollover shape). `sessionId` alone names the reserved successor.
    private func decodeStatus(sessionID: String? = nil, openSessionID: String? = nil) throws -> HomeStatusDTO {
        var json = validStatus
        var fields: [String] = []
        if let sessionID { fields.append(#""sessionId":"\#(sessionID)""#) }
        if let open = openSessionID ?? sessionID { fields.append(#""openSessionId":"\#(open)""#) }
        if !fields.isEmpty { json = String(json.dropLast()) + "," + fields.joined(separator: ",") + "}" }
        return try HomeStatusDTO.decode(JSONValue.parse(Data(json.utf8)))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not reached within 2.5 seconds")
    }
}

private extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
