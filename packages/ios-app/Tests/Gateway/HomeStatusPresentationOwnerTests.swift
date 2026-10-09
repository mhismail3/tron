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

    func testUnresolvedClaimReadsPerConnectionAndNeverPolls() async throws {
        let (owner, coordinator, token) = mountedOwner()
        let claimed = expectation(description: "claim read")
        let reconnected = expectation(description: "read after connection admission")
        var fetchCount = 0
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true, cadence: .connectionOnly(sessionID: "home-session")) { _ in
            fetchCount += 1
            if fetchCount == 1 { claimed.fulfill() }
            if fetchCount == 2 { reconnected.fulfill() }
            throw URLError(.networkConnectionLost)
        }
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
        let (owner, coordinator, token) = mountedOwner()
        var fetchCount = 0
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true, cadence: .connectionOnly(sessionID: "home-session")) { _ in
            fetchCount += 1
            return try self.decodeStatus(sessionID: "home-session")
        }
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

    func testNonMatchingClaimReleasesEveryReadButKeepsStatus() async throws {
        let (owner, coordinator, token) = mountedOwner()
        var fetchCount = 0
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true, cadence: .connectionOnly(sessionID: "ordinary-session")) { _ in
            fetchCount += 1
            return try self.decodeStatus(sessionID: "home-session")
        }
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
        let (owner, coordinator, token) = mountedOwner()
        var fetchCount = 0
        var gated: [CheckedContinuation<HomeStatusDTO, Error>] = []
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true, cadence: .connectionOnly(sessionID: "home-session")) { _ in
            fetchCount += 1
            if fetchCount == 1 {
                return try await withCheckedThrowingContinuation { gated.append($0) }
            }
            return try self.decodeStatus(sessionID: "home-session")
        }
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
        let (owner, coordinator, token) = mountedOwner()
        var fetchCount = 0
        var gated: [CheckedContinuation<HomeStatusDTO, Error>] = []
        owner.configure(profileID: "p", connectionID: "c", capabilityEnabled: true, cadence: .connectionOnly(sessionID: "home-session")) { _ in
            fetchCount += 1
            if fetchCount <= 2 {
                return try await withCheckedThrowingContinuation { gated.append($0) }
            }
            return try self.decodeStatus(sessionID: "home-session")
        }
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

    private func decodeStatus(sessionID: String? = nil) throws -> HomeStatusDTO {
        var json = validStatus
        if let sessionID {
            json = String(json.dropLast()) + #","sessionId":"\#(sessionID)"}"#
        }
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
