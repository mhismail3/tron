import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("AppModel pairing attempt ownership", .serialized)
struct AppModelPairingAttemptTests {
    private let firstInvitation = PairingInvitation(
        host: "first.gateway.test",
        port: 9_847,
        code: "11111111",
        machineId: nil,
        label: "First Mac"
    )
    private let secondInvitation = PairingInvitation(
        host: "second.gateway.test",
        port: 9_848,
        code: "22222222",
        machineId: nil,
        label: "Second Mac"
    )

    @Test("a late HTTP success after forget cannot commit metadata, token, or connect")
    func lateResultAfterForget() async throws {
        try await withFixture(ids: [uuid(1)]) { fixture in
            let pairing = fixture.startPairing(self.firstInvitation)
            try await fixture.http.waitForRequests(1)

            await fixture.model.forgetCurrentGateway()
            try await fixture.http.succeed(request: 0, machineID: "stale-machine", token: "stale-token")
            await expectCancellation(pairing)

            #expect(fixture.commit.saved.isEmpty)
            #expect(fixture.store.profiles.isEmpty)
            #expect(fixture.socketFactory.requests.isEmpty)
            #expect(fixture.model.connectionState == .unpaired)
        }
    }

    @Test("an older HTTP success is rejected after a newer pairing attempt owns enrollment")
    func olderResultAfterReplacement() async throws {
        try await withFixture(ids: [uuid(1), uuid(2)]) { fixture in
            let older = fixture.startPairing(self.firstInvitation)
            try await fixture.http.waitForRequests(1)
            let newer = fixture.startPairing(self.secondInvitation)
            try await fixture.http.waitForRequests(2)

            try await fixture.http.succeed(request: 0, machineID: "old-machine", token: "old-token")
            await expectCancellation(older)
            #expect(fixture.commit.saved.isEmpty)
            #expect(fixture.store.profiles.isEmpty)
            #expect(fixture.socketFactory.requests.isEmpty)

            try await fixture.http.fail(request: 1, code: "invalid_pairing_code")
            do {
                try await valueOfOwnedTask(newer)
                Issue.record("newer pairing unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "invalid_pairing_code")
            } catch {
                Issue.record("unexpected newer-attempt error: \(error)")
            }
            #expect(fixture.commit.saved.isEmpty)
            #expect(fixture.store.profiles.isEmpty)
            #expect(fixture.socketFactory.requests.isEmpty)
            #expect(fixture.model.connectionState == .unpaired)
        }
    }

    @Test("a failed pairing commit restores the prior lifecycle instead of stranding transition")
    func failedCommitRestoresLifecycle() async throws {
        try await withFixture(ids: [uuid(1)], commitFails: true) { fixture in
            let pairing = fixture.startPairing(self.firstInvitation)
            try await fixture.http.waitForRequests(1)
            try await fixture.http.succeed(request: 0, machineID: "uncommitted-machine", token: "uncommitted-token")

            do {
                try await valueOfOwnedTask(pairing)
                Issue.record("failed commit unexpectedly succeeded")
            } catch is PairingCommitFixtureError {
                // The injected commit failure is expected.
            } catch {
                Issue.record("unexpected commit error: \(error)")
            }
            #expect(fixture.model.connectionState == .unpaired)
            #expect(fixture.store.profiles.isEmpty)
            #expect(fixture.socketFactory.requests.isEmpty)

            await fixture.model.start()
            #expect(fixture.model.connectionState == .unpaired)
            #expect(fixture.model.hasResolvedLaunchState)
        }
    }

    @Test("switch invalidates pending enrollment without reading the real Keychain")
    func switchInvalidatesPendingPairing() async throws {
        try await withFixture(ids: [uuid(1)]) { fixture in
            let existingID = "existing-\(UUID().uuidString)"
            let existing = GatewayProfile(
                id: existingID,
                label: "Existing Mac",
                host: "existing.gateway.test",
                port: 9_847,
                machineId: existingID,
                deviceId: "existing-device"
            )
            fixture.defaults.set(try JSONEncoder.gateway.encode([existing]), forKey: "gatewayProfiles.v1")
            fixture.defaults.set(existing.id, forKey: "selectedGateway.v1")
            let pairing = fixture.startPairing(self.firstInvitation)
            try await fixture.http.waitForRequests(1)

            await fixture.model.switchGateway(existing)
            try await fixture.http.succeed(request: 0, machineID: "stale-machine", token: "stale-token")
            await expectCancellation(pairing)

            #expect(fixture.tokenLookup.profileIDs == [existing.id])
            #expect(fixture.commit.saved.isEmpty)
            #expect(fixture.store.profiles == [existing])
            #expect(fixture.socketFactory.requests.isEmpty)
            #expect(fixture.model.connectionState == .unpaired)
            #expect(fixture.model.hasResolvedLaunchState)
            #expect(fixture.model.lastError == "This gateway no longer has a Keychain token. Pair it again.")
        }
    }

    @Test("the exact attempt remains cancellable while Gateway connect is suspended")
    func ownershipThroughConnect() async throws {
        try await withFixture(ids: [uuid(1)]) { fixture in
            let pairing = fixture.startPairing(self.firstInvitation)
            try await fixture.http.waitForRequests(1)
            try await fixture.http.succeed(request: 0, machineID: "accepted-machine", token: "accepted-token")
            try await fixture.socket.waitUntilSent(count: 1)

            #expect(fixture.commit.saved.map(\.token) == ["accepted-token"])
            #expect(fixture.socketFactory.requests.count == 1)
            await fixture.model.forgetCurrentGateway()
            await expectCancellation(pairing)

            #expect(fixture.model.connectionState == .unpaired)
            #expect(fixture.model.gatewayInfo == nil)
            #expect(fixture.model.hasResolvedLaunchState)
        }
    }

    @Test("the event listener does not retain AppModel or GatewayClient after owner release")
    func eventListenerOwnerRelease() {
        weak var weakModel: AppModel?
        weak var weakClient: GatewayClient?
        let suite = "AppModelPairingAttemptTests.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        do {
            let client = GatewayClient()
            let model = AppModel(
                client: client,
                profiles: GatewayProfileStore(defaults: defaults),
                cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: suite))
            )
            weakModel = model
            weakClient = client
        }
        defaults.removePersistentDomain(forName: suite)

        #expect(weakModel == nil)
        #expect(weakClient == nil)
    }

    private func withFixture(
        ids: [UUID],
        commitFails: Bool = false,
        operation: @escaping @MainActor @Sendable (PairingFixture) async throws -> Void
    ) async throws {
        let fixture = makeFixture(ids: ids, commitFails: commitFails)
        let http = fixture.http
        do {
            try await withTestWatchdog {
                try await withTaskCancellationHandler {
                    try await operation(fixture)
                } onCancel: {
                    Task { await http.cancelAll() }
                }
            }
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    private func makeFixture(ids: [UUID], commitFails: Bool) -> PairingFixture {
        let suite = "AppModelPairingAttemptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = GatewayProfileStore(defaults: defaults)
        let http = LateResultPairingHTTPTransport()
        let socket = ScriptedGatewaySocket()
        let socketFactory = ScriptedGatewaySocketFactory(socket: socket)
        let client = GatewayClient(socketFactory: socketFactory.factory)
        let commit = PairingCommitRecorder()
        let tokenLookup = ProfileTokenLookupRecorder()
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        let model = AppModel(
            client: client,
            profiles: store,
            cache: SnapshotCache(root: cacheRoot),
            uuidSource: SequenceUUIDSource(ids).source,
            pairer: GatewayPairer(transport: http.transport),
            pairingCommit: { profile, token in
                if commitFails { throw PairingCommitFixtureError() }
                commit.record(profile: profile, token: token)
            },
            profileTokenLookup: { profile in tokenLookup.token(for: profile) }
        )
        return PairingFixture(
            suiteName: suite,
            defaults: defaults,
            standardDefaults: StandardPairingDefaults.capture(),
            cacheRoot: cacheRoot,
            store: store,
            http: http,
            socket: socket,
            socketFactory: socketFactory,
            client: client,
            commit: commit,
            tokenLookup: tokenLookup,
            model: model,
            pairingTasks: PairingTaskOwner()
        )
    }

    private func expectCancellation(_ task: Task<Void, Error>) async {
        do {
            try await valueOfOwnedTask(task)
            Issue.record("cancelled pairing unexpectedly succeeded")
        } catch is CancellationError {
            // Supersession/teardown is the only silent pairing outcome.
        } catch {
            Issue.record("unexpected pairing error: \(error)")
        }
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

@MainActor
private final class PairingCommitRecorder {
    struct Saved {
        let profile: GatewayProfile
        let token: String
    }

    private(set) var saved: [Saved] = []

    func record(profile: GatewayProfile, token: String) {
        saved.append(Saved(profile: profile, token: token))
    }
}

@MainActor
private final class ProfileTokenLookupRecorder {
    private(set) var profileIDs: [String] = []

    func token(for profile: GatewayProfile) -> String? {
        profileIDs.append(profile.id)
        return nil
    }
}

@MainActor
private struct PairingFixture {
    let suiteName: String
    let defaults: UserDefaults
    let standardDefaults: StandardPairingDefaults
    let cacheRoot: URL
    let store: GatewayProfileStore
    let http: LateResultPairingHTTPTransport
    let socket: ScriptedGatewaySocket
    let socketFactory: ScriptedGatewaySocketFactory
    let client: GatewayClient
    let commit: PairingCommitRecorder
    let tokenLookup: ProfileTokenLookupRecorder
    let model: AppModel
    let pairingTasks: PairingTaskOwner

    func startPairing(_ invitation: PairingInvitation) -> Task<Void, Error> {
        let task = Task { try await model.pair(invitation) }
        pairingTasks.append(task)
        return task
    }

    func cleanup() async {
        let tasks = pairingTasks.cancelAll()
        await http.cancelAll()
        for task in tasks { _ = try? await task.value }
        await client.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
        standardDefaults.restore()
    }
}

@MainActor
private final class PairingTaskOwner {
    private var tasks: [Task<Void, Error>] = []

    func append(_ task: Task<Void, Error>) {
        tasks.append(task)
    }

    func cancelAll() -> [Task<Void, Error>] {
        let owned = tasks
        tasks.removeAll()
        for task in owned { task.cancel() }
        return owned
    }
}

@MainActor
private struct StandardPairingDefaults {
    private struct Value {
        let existed: Bool
        let bool: Bool
    }

    private let tronSetup: Value
    private let legacySetup: Value

    static func capture() -> StandardPairingDefaults {
        let defaults = UserDefaults.standard
        return StandardPairingDefaults(
            tronSetup: Value(
                existed: defaults.object(forKey: "tronSetupComplete.v1") != nil,
                bool: defaults.bool(forKey: "tronSetupComplete.v1")
            ),
            legacySetup: Value(
                existed: defaults.object(forKey: "piSetupComplete.v1") != nil,
                bool: defaults.bool(forKey: "piSetupComplete.v1")
            )
        )
    }

    func restore() {
        restore(tronSetup, key: "tronSetupComplete.v1")
        restore(legacySetup, key: "piSetupComplete.v1")
    }

    private func restore(_ value: Value, key: String) {
        if value.existed {
            UserDefaults.standard.set(value.bool, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private actor LateResultPairingHTTPTransport {
    private struct PendingRequest {
        let request: URLRequest
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    }

    private struct RequestWaiter {
        let token: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var pending: [Int: PendingRequest] = [:]
    private var requestCount = 0
    private var requestWaiters: [RequestWaiter] = []
    private var nextWaiterToken = 0

    nonisolated var transport: HTTPDataTransport {
        HTTPDataTransport { request in
            try await self.suspend(request)
        }
    }

    func waitForRequests(_ count: Int) async throws {
        if requestCount >= count { return }
        let token = nextWaiterToken
        nextWaiterToken += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requestWaiters.append(RequestWaiter(token: token, count: count, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    func succeed(request index: Int, machineID: String, token: String) throws {
        try resume(
            request: index,
            status: 200,
            body: """
            {"deviceId":"device-\(machineID)","token":"\(token)","machineId":"\(machineID)","machineName":"Test Mac"}
            """
        )
    }

    func fail(request index: Int, code: String) throws {
        try resume(
            request: index,
            status: 403,
            body: """
            {"error":{"code":"\(code)","message":"Pairing failed.","retryable":false,"details":null}}
            """
        )
    }

    func cancelAll() {
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.continuation.resume(throwing: CancellationError()) }

        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func suspend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let index = requestCount
            requestCount += 1
            pending[index] = PendingRequest(request: request, continuation: continuation)
            resumeSatisfiedWaiters()
        }
    }

    private func resume(request index: Int, status: Int, body: String) throws {
        guard let pendingRequest = pending.removeValue(forKey: index) else {
            throw PairingTransportFixtureError.missingRequest(index)
        }
        let url = pendingRequest.request.url!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        pendingRequest.continuation.resume(returning: (Data(body.utf8), response))
    }

    private func cancelWaiter(token: Int) {
        guard let index = requestWaiters.firstIndex(where: { $0.token == token }) else { return }
        requestWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.count }
        requestWaiters.removeAll { requestCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}

private struct PairingCommitFixtureError: Error {}

private enum PairingTransportFixtureError: Error {
    case missingRequest(Int)
}
