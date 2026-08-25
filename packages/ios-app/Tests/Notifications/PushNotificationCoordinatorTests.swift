import CryptoKit
import DeviceCheck
import Foundation
import Testing

private final class PushFixtureBundleMarker {}
@testable import TronMobile

@Suite("Push notification registration")
struct PushNotificationCoordinatorTests {
    @Test("product origin admits only one exact HTTPS origin")
    func productOriginAdmission() {
        #expect(PushProductConfiguration.admit(URL(string: "https://push.example.test")!) != nil)
        #expect(PushProductConfiguration.admit(URL(string: "http://push.example.test")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://user@push.example.test")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://push.example.test/base")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://push.example.test?next=evil")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://localhost")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://127.0.0.1")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://[::1]")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://relay.local")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://-bad.example")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://bad-.example")!) == nil)
        #expect(PushProductConfiguration.admit(URL(string: "https://bad..example")!) == nil)
    }

    @Test("registration payload matches the shared cross-runtime canonical fixture")
    func canonicalRegistration() throws {
        let bundle = Bundle(for: PushFixtureBundleMarker.self)
        let url = try #require(
            bundle.url(forResource: "push-v3", withExtension: "json")
                ?? bundle.url(forResource: "push-v3", withExtension: "json", subdirectory: "protocol-fixtures")
        )
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let registration = try #require(root["registration"] as? [String: Any])
        let fields = try #require(registration["fields"] as? [String: Any])
        let version = try #require(fields["version"] as? Int)
        let challengeID = try #require(fields["challengeId"] as? String)
        let challenge = try #require(fields["challenge"] as? String)
        let keyID = try #require(fields["keyId"] as? String)
        let token = try #require(fields["apnsToken"] as? String)
        let routeValue = try #require(fields["route"] as? String)
        let route = try #require(PushRoute(rawValue: routeValue))
        let bindingHash = try #require(fields["bindingHash"] as? String)
        let payload = PushWorkerClient.RegistrationPayload(
            version: version, challengeId: challengeID, challenge: challenge,
            keyId: keyID, apnsToken: token, route: route, bindingHash: bindingHash
        )
        let data = try PushWorkerClient.canonicalData(payload)
        #expect(String(decoding: data, as: UTF8.self) == registration["canonicalUTF8"] as? String)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == registration["clientDataHashHex"] as? String)
    }

    @Test("Gateway readiness result matches the shared cross-runtime fixture")
    func gatewayReadinessFixture() throws {
        let bundle = Bundle(for: PushFixtureBundleMarker.self)
        let url = try #require(
            bundle.url(forResource: "push-v3", withExtension: "json")
                ?? bundle.url(forResource: "push-v3", withExtension: "json", subdirectory: "protocol-fixtures")
        )
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let gateway = try #require(root["gatewayUpsert"] as? [String: Any])
        let expected = try #require(gateway["expectedStatus"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        let status = try JSONDecoder().decode(PushRegistrationStatus.self, from: data)
        #expect(status.available)
        #expect(status.registered)
        #expect(status.deviceRegistered)
        #expect(status.enabledDeviceCount == 1)
        #expect(status.pendingCount == 0)
        #expect(status.notifyWhenAskPresented)
    }

    @Test("tap admission ignores arbitrary routing data")
    func tapAdmission() {
        #expect(PushNotificationTap.admit(["sessionId": "session-123"]).sessionID == "session-123")
        #expect(PushNotificationTap.admit(["sessionId": "../../private"]).sessionID == nil)
        #expect(PushNotificationTap.admit(["url": "https://evil.test"]).sessionID == nil)
    }

    @MainActor
    @Test("permission denial is isolated from Gateway connectivity")
    func deniedPermission() async {
        let store = MemoryPushCredentialStore()
        let notifications = PushNotificationSystem(
            authorization: { .denied },
            requestAuthorization: { Issue.record("permission prompt should not repeat"); return false },
            registerForRemoteNotifications: { Issue.record("APNs registration should not start") }
        )
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: notifications,
            appAttest: supportedAttest,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!)
        )
        let client = GatewayClient()
        await coordinator.reconcile(profile: profile, connected: false, client: client)
        #expect(coordinator.readiness == .denied)
        #expect(store.value == nil)
    }

    @MainActor
    @Test("permission denial invalidates a late proof before grant persistence")
    func denialRacingLateProof() async throws {
        let authorization = PushAuthorizationController(.allowed)
        let proof = LatePushProofTransport()
        let original = PushCredentialDocument(appAttestKeyID: "key", apnsToken: "01", grants: [:])
        let store = MemoryPushCredentialStore(initial: original)
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: authorization.system,
            appAttest: PushAttestRecorder().client,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: BoundedHTTPDataTransport { request, maximumBytes in
                try await proof.handle(request, maximumBytes: maximumBytes)
            }
        )
        let (client, socket) = try await connectedGateway(for: profile)
        defer { Task { await client.close() } }
        let gatewayBaseline = await socket.sentFrames().count

        await coordinator.reconcile(profile: profile, connected: true, client: client)
        await proof.waitUntilInstallationStarted()
        await authorization.set(.denied)
        await coordinator.reconcile(profile: profile, connected: true, client: client)
        await proof.releaseInstallation()
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.readiness == .denied)
        #expect(coordinator.diagnostic == .idle)
        #expect(store.value == original)
        #expect(await socket.sentFrames().count == gatewayBaseline)
    }

    @MainActor
    @Test("profile replacement during Gateway transfer cannot publish stale readiness")
    func profileReplacementDuringTransfer() async throws {
        let grant = matchingGrant(profileID: profile.id, token: "01")
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "key", apnsToken: "01", grants: [profile.id: grant]
        ))
        let challenge = SuspendedPushChallengeTransport()
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: allowedNotifications,
            appAttest: PushAttestRecorder().client,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: BoundedHTTPDataTransport { request, maximumBytes in
                try await challenge.handle(request, maximumBytes: maximumBytes)
            }
        )
        let (client, socket) = try await connectedGateway(for: profile)
        defer { Task { await client.close() } }

        await coordinator.reconcile(profile: profile, connected: true, client: client)
        try await socket.waitUntilSent(count: 2)
        let replacement = GatewayProfile(
            id: "profile-2", label: "Other Mac", host: "other.test", port: 9_847,
            machineId: "machine-2", deviceId: "device-2"
        )
        await coordinator.reconcile(profile: replacement, connected: false, client: GatewayClient())
        await challenge.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.readiness == .registering)
        #expect(coordinator.diagnostic == .requestingChallenge)
        #expect(store.value?.grants[profile.id] == grant)
        await coordinator.reconcile(profile: nil, connected: false, client: GatewayClient())
    }

    @MainActor
    @Test("newly proved grant transfer cannot publish after profile teardown")
    func newGrantTransferDuringProfileTeardown() async throws {
        let script = ScriptedPushTransport(installations: [.status(201)])
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "key", apnsToken: "01", grants: [:]
        ))
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: allowedNotifications,
            appAttest: PushAttestRecorder().client,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: BoundedHTTPDataTransport { request, maximumBytes in
                try await script.handle(request, maximumBytes: maximumBytes)
            }
        )
        let (client, socket) = try await connectedGateway(for: profile)
        defer { Task { await client.close() } }

        await coordinator.reconcile(profile: profile, connected: true, client: client)
        try await socket.waitUntilSent(count: 2)
        let provedGrant = try #require(store.value?.grants[profile.id])
        await coordinator.reconcile(profile: nil, connected: false, client: GatewayClient())
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.readiness == .unavailable)
        #expect(coordinator.diagnostic == .idle)
        #expect(store.value?.grants[profile.id] == provedGrant)
        #expect(store.value?.appAttestKeyRejected != true)
    }

    @MainActor
    @Test("APNs replacement during Gateway transfer cannot publish old-token readiness")
    func tokenReplacementDuringTransfer() async throws {
        let grant = matchingGrant(profileID: profile.id, token: "01")
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "key", apnsToken: "01", grants: [profile.id: grant]
        ))
        let challenge = SuspendedPushChallengeTransport()
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: allowedNotifications,
            appAttest: PushAttestRecorder().client,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: BoundedHTTPDataTransport { request, maximumBytes in
                try await challenge.handle(request, maximumBytes: maximumBytes)
            }
        )
        let (client, socket) = try await connectedGateway(for: profile)
        defer { Task { await client.close() } }

        await coordinator.reconcile(profile: profile, connected: true, client: client)
        try await socket.waitUntilSent(count: 2)
        coordinator.receiveDeviceToken(Data([0x02]))
        await challenge.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.readiness == .registering)
        #expect(coordinator.diagnostic == .requestingChallenge)
        #expect(store.value?.apnsToken == "02")
        #expect(store.value?.grants[profile.id] == grant)
        await coordinator.reconcile(profile: nil, connected: false, client: GatewayClient())
    }

    @MainActor
    @Test("APNs token is attested and grant is persisted before Gateway transfer")
    func registrationFlow() async throws {
        let store = MemoryPushCredentialStore()
        let requestLog = PushRequestLog()
        let transport = BoundedHTTPDataTransport { request, maximumBytes in
            await requestLog.append(request, maximumBytes: maximumBytes)
            let path = request.url?.path
            let body: String
            if path == "/v3/attestation/challenge" {
                body = #"{"challengeId":"challenge-id","challenge":"server-nonce","expiresAt":"2026-08-24T06:00:00Z"}"#
            } else {
                body = #"{"version":1,"installationId":"installation_1","grantId":"grant_1","grantSecret":"0123456789abcdef0123456789abcdef","route":"beta"}"#
            }
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: path == "/v3/installations" ? 201 : 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let notifications = PushNotificationSystem(
            authorization: { .allowed },
            requestAuthorization: { true },
            registerForRemoteNotifications: {}
        )
        let attest = PushAppAttestClient(
            isSupported: { true },
            generateKey: { "key_1" },
            attest: { key, hash in
                #expect(key == "key_1")
                #expect(hash.count == 32)
                return Data("attestation".utf8)
            },
            assert: { _, _ in
                Issue.record("first registration must attest")
                return Data()
            }
        )
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: notifications,
            appAttest: attest,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: transport,
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
        let client = GatewayClient()
        await coordinator.reconcile(profile: profile, connected: false, client: client)
        coordinator.receiveDeviceToken(Data([0x01, 0x02, 0xff]))

        for _ in 0..<100 where store.value?.grants[Self.profile.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let grant = try #require(store.value?.grants[Self.profile.id])
        #expect(grant.installationID == "installation_1")
        #expect(store.value?.apnsToken == "0102ff")
        let requests = await requestLog.requests
        #expect(requests.map { $0.url?.path } == ["/v3/attestation/challenge", "/v3/installations"])
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].timeoutInterval == 15)
        #expect(requests[1].timeoutInterval == 60)
        let registrationBody = try #require(requests[1].httpBody)
        let registration = try #require(JSONSerialization.jsonObject(with: registrationBody) as? [String: Any])
        #expect(registration["proof"] as? String == "attestation")
        #expect(registration["route"] as? String == "beta")
        #expect(registration["attestationObject"] as? String != nil)
        #expect(registration["payload"] == nil)
        #expect(requests.allSatisfy { $0.url?.host == "push.example.test" })
        let responseBounds = await requestLog.maximumBytes
        #expect(responseBounds.allSatisfy { $0 == 16 * 1024 })
    }

    @MainActor
    @Test("timeout retries with a fresh challenge and persisted-key assertion")
    func timeoutThenAssertionSuccess() async throws {
        let script = ScriptedPushTransport(installations: [.timeout, .status(201)])
        let attest = PushAttestRecorder(assertionResults: [.success(Data("one".utf8)), .success(Data("two".utf8))])
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "persisted-key", apnsToken: "01", grants: [:]
        ))
        let retries = PushRetryRecorder()
        let coordinator = makeCoordinator(store: store, script: script, attest: attest, retries: retries)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await waitForGrant(in: store)

        #expect(await script.challengeCount == 2)
        #expect(await script.submittedModes == ["assertion", "assertion"])
        #expect(await script.submittedChallenges == ["challenge-1", "challenge-2"])
        #expect(await attest.assertionKeys == ["persisted-key", "persisted-key"])
        #expect(await retries.values == [.milliseconds(250)])
        #expect(store.value?.appAttestKeyID == "persisted-key")
    }

    @MainActor
    @Test("assertion 401 rotates only the key and permits one fresh attestation")
    func assertion401ThenFreshAttestation() async throws {
        let script = ScriptedPushTransport(installations: [.status(401), .status(201)])
        let attest = PushAttestRecorder(generatedKeys: ["fresh-key"])
        let originalGrant = PushGrant(
            profileID: "other", installationID: "install_other", grantID: "grant_other",
            grantSecret: String(repeating: "s", count: 32), tokenHash: "hash"
        )
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "invalid-key", apnsToken: "01", grants: ["other": originalGrant]
        ))
        let coordinator = makeCoordinator(store: store, script: script, attest: attest)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await waitForGrant(in: store)

        #expect(await script.submittedModes == ["assertion", "attestation"])
        #expect(await attest.generatedCount == 1)
        #expect(store.value?.appAttestKeyID == "fresh-key")
        #expect(store.value?.grants["other"] == originalGrant)
        #expect(store.value?.apnsToken == "01")
    }

    @MainActor
    @Test("typed DCAppAttest invalid-key uses the same one-time recovery")
    func typedLocalInvalidKeyRecovery() async throws {
        let typedInvalidKey = NSError(
            domain: DCError.errorDomain,
            code: DCError.Code.invalidKey.rawValue
        )
        let script = ScriptedPushTransport(installations: [.status(201)])
        let attest = PushAttestRecorder(
            generatedKeys: ["replacement-key"],
            assertionResults: [.failure(typedInvalidKey)]
        )
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "reinstalled-key", apnsToken: "01", grants: [:]
        ))
        let coordinator = makeCoordinator(store: store, script: script, attest: attest)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await waitForGrant(in: store)

        #expect(await script.submittedModes == ["attestation"])
        #expect(await script.challengeCount == 2)
        #expect(await attest.generatedCount == 1)
        #expect(store.value?.appAttestKeyID == "replacement-key")
    }

    @MainActor
    @Test("fresh attestation rejection is persisted and repeated reconcile does not churn")
    func repeatedAttestation401Stops() async throws {
        let script = ScriptedPushTransport(installations: [.status(401), .status(401)])
        let attest = PushAttestRecorder(generatedKeys: ["fresh-key", "must-not-generate"])
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "old-key", apnsToken: "01", grants: [:]
        ))
        let coordinator = makeCoordinator(store: store, script: script, attest: attest)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await waitUntil { coordinator.diagnostic == .stoppedRejected }
        #expect(await script.submittedModes == ["assertion", "attestation"])
        #expect(await attest.generatedCount == 1)
        #expect(store.value?.appAttestKeyID == "fresh-key")
        #expect(store.value?.appAttestKeyRejected == true)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await Task.sleep(for: .milliseconds(30))
        #expect(await script.submittedModes == ["assertion", "attestation"])
        #expect(await attest.generatedCount == 1)
    }

    @MainActor
    @Test("retryable failures use bounded backoff and stop at exhaustion")
    func retryBoundsAndBackoff() async throws {
        let script = ScriptedPushTransport(installations: [.status(503), .status(503), .status(503)])
        let attest = PushAttestRecorder()
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "key", apnsToken: "01", grants: [:]
        ))
        let retries = PushRetryRecorder()
        let coordinator = makeCoordinator(store: store, script: script, attest: attest, retries: retries)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await waitUntil { coordinator.diagnostic == .stoppedExhausted }

        #expect(await script.challengeCount == 3)
        #expect(await script.submittedModes == ["assertion", "assertion", "assertion"])
        #expect(await retries.values == [.milliseconds(250), .milliseconds(750)])
        #expect(store.value?.appAttestKeyID == "key")
        #expect(store.value?.apnsToken == "01")
    }

    @MainActor
    @Test("profile cancellation cannot commit a late proof")
    func profileCancellation() async throws {
        let started = PushCancellationProbe()
        let transport = BoundedHTTPDataTransport { request, _ in
            await started.markStarted()
            try await Task.sleep(for: .seconds(30))
            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let original = PushCredentialDocument(appAttestKeyID: "key", apnsToken: "01", grants: [:])
        let store = MemoryPushCredentialStore(initial: original)
        let coordinator = PushNotificationCoordinator(
            credentials: store,
            notifications: allowedNotifications,
            appAttest: PushAttestRecorder().client,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: transport
        )
        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        await started.waitUntilStarted()
        await coordinator.reconcile(profile: nil, connected: false, client: GatewayClient())
        try await Task.sleep(for: .milliseconds(30))

        #expect(coordinator.readiness == .unavailable)
        #expect(coordinator.diagnostic == .idle)
        #expect(store.value == original)
    }

    @MainActor
    @Test("nonretryable rejection stops without backoff or key rotation")
    func nonretryableStop() async throws {
        let script = ScriptedPushTransport(installations: [.status(422)])
        let attest = PushAttestRecorder()
        let store = MemoryPushCredentialStore(initial: PushCredentialDocument(
            appAttestKeyID: "key", apnsToken: "01", grants: [:]
        ))
        let retries = PushRetryRecorder()
        let coordinator = makeCoordinator(store: store, script: script, attest: attest, retries: retries)

        await coordinator.reconcile(profile: profile, connected: false, client: GatewayClient())
        try await waitUntil { coordinator.diagnostic == .stoppedRejected }
        #expect(await retries.values.isEmpty)
        #expect(await script.submittedModes == ["assertion"])
        #expect(store.value?.appAttestKeyID == "key")
    }

    @Test("diagnostics are fixed privacy-safe stage text")
    func diagnosticPrivacy() {
        let values = [
            PushRegistrationDiagnostic.idle, .waitingForToken, .requestingChallenge,
            .generatingKey, .generatingAttestation, .generatingAssertion, .submittingProof,
            .retryBackoff, .transferringGrant, .complete, .stoppedRejected,
            .stoppedInvalidKey, .stoppedInvalidResponse, .stoppedPersistence,
            .stoppedExhausted, .stoppedUnavailable,
        ].map(\.rawValue)
        let forbidden = ["https://", "profile-1", "challenge-1", "key_1", "0123456789abcdef", "certificate", "bindingHash"]
        #expect(values.allSatisfy { value in
            forbidden.allSatisfy { !value.localizedCaseInsensitiveContains($0) }
        })
        #expect(values.allSatisfy { $0.utf8.count <= 32 })
    }

    @MainActor
    private func makeCoordinator(
        store: MemoryPushCredentialStore,
        script: ScriptedPushTransport,
        attest: PushAttestRecorder,
        retries: PushRetryRecorder = PushRetryRecorder()
    ) -> PushNotificationCoordinator {
        let continuous = ContinuousClock()
        return PushNotificationCoordinator(
            credentials: store,
            notifications: allowedNotifications,
            appAttest: attest.client,
            configuration: PushProductConfiguration(origin: URL(string: "https://push.example.test")!),
            transport: BoundedHTTPDataTransport { request, maximumBytes in
                try await script.handle(request, maximumBytes: maximumBytes)
            },
            clock: MonotonicClock(
                now: { continuous.now },
                sleep: { duration in await retries.append(duration) }
            )
        )
    }

    private var allowedNotifications: PushNotificationSystem {
        PushNotificationSystem(
            authorization: { .allowed },
            requestAuthorization: { true },
            registerForRemoteNotifications: {}
        )
    }

    @MainActor
    private func waitForGrant(in store: MemoryPushCredentialStore) async throws {
        try await waitUntil { store.value?.grants[Self.profile.id] != nil }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for push registration state")
    }

    private static let profile = GatewayProfile(
        id: "profile-1",
        label: "Mac",
        host: "gateway.test",
        port: 9_847,
        machineId: "machine-1",
        deviceId: "device-1"
    )

    private var profile: GatewayProfile { Self.profile }

    private func matchingGrant(profileID: String, token: String) -> PushGrant {
        PushGrant(
            profileID: profileID,
            installationID: "installation_existing",
            grantID: "grant_existing",
            grantSecret: String(repeating: "s", count: 32),
            tokenHash: SHA256.hash(data: Data("tron-apns-token-v1\0\(token)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        )
    }

    private func connectedGateway(
        for profile: GatewayProfile
    ) async throws -> (GatewayClient, ScriptedGatewaySocket) {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"0.84.1","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine-1","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#.utf8))
        _ = try await client.connect(profile: profile, token: "token")
        return (client, socket)
    }

    private var supportedAttest: PushAppAttestClient {
        PushAppAttestClient(
            isSupported: { true },
            generateKey: { "unused" },
            attest: { _, _ in Data() },
            assert: { _, _ in Data() }
        )
    }
}

private actor PushAuthorizationController {
    private var value: PushAuthorization

    init(_ value: PushAuthorization) { self.value = value }

    nonisolated var system: PushNotificationSystem {
        PushNotificationSystem(
            authorization: { await self.authorization() },
            requestAuthorization: { await self.authorization() == .allowed },
            registerForRemoteNotifications: {}
        )
    }

    func set(_ value: PushAuthorization) { self.value = value }
    private func authorization() -> PushAuthorization { value }
}

private actor LatePushProofTransport {
    private var installationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var installationContinuation: CheckedContinuation<Void, Never>?

    func handle(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        #expect(maximumBytes == 16 * 1024)
        if request.url?.path == "/v3/attestation/challenge" {
            return response(
                request,
                status: 200,
                body: #"{"challengeId":"challenge-late","challenge":"nonce-late","expiresAt":"2026-08-24T06:00:00Z"}"#
            )
        }
        installationStarted = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { installationContinuation = $0 }
        return response(
            request,
            status: 201,
            body: #"{"version":1,"installationId":"installation_late","grantId":"grant_late","grantSecret":"0123456789abcdef0123456789abcdef","route":"beta"}"#
        )
    }

    func waitUntilInstallationStarted() async {
        if installationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseInstallation() {
        installationContinuation?.resume()
        installationContinuation = nil
    }

    private func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (Data, HTTPURLResponse) {
        (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private actor SuspendedPushChallengeTransport {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func handle(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        #expect(maximumBytes == 16 * 1024)
        started = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class MemoryPushCredentialStore: PushCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PushCredentialDocument?
    init(initial: PushCredentialDocument? = nil) { stored = initial }
    var value: PushCredentialDocument? { lock.withLock { stored } }
    func load() throws -> PushCredentialDocument? { value }
    func save(_ document: PushCredentialDocument) throws { lock.withLock { stored = document } }
}

private actor ScriptedPushTransport {
    enum InstallationResult: Sendable {
        case status(Int)
        case timeout
    }

    private var installations: [InstallationResult]
    private(set) var challengeCount = 0
    private(set) var submittedModes: [String] = []
    private(set) var submittedChallenges: [String] = []

    init(installations: [InstallationResult]) { self.installations = installations }

    func handle(_ request: URLRequest, maximumBytes: Int) throws -> (Data, HTTPURLResponse) {
        #expect(maximumBytes == 16 * 1024)
        if request.url?.path == "/v3/attestation/challenge" {
            challengeCount += 1
            let body = """
            {"challengeId":"challenge-\(challengeCount)","challenge":"nonce-\(challengeCount)","expiresAt":"2026-08-24T06:00:00Z"}
            """
            return response(request, status: 200, body: body)
        }
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        submittedModes.append(try #require(object["proof"] as? String))
        submittedChallenges.append(try #require(object["challengeId"] as? String))
        let next = installations.isEmpty ? .status(500) : installations.removeFirst()
        switch next {
        case .timeout:
            throw URLError(.timedOut)
        case .status(let status):
            let responseBody = status == 201
                ? #"{"version":1,"installationId":"installation_1","grantId":"grant_1","grantSecret":"0123456789abcdef0123456789abcdef","route":"beta"}"#
                : #"{"error":"rejected"}"#
            return response(request, status: status, body: responseBody)
        }
    }

    private func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (Data, HTTPURLResponse) {
        (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

private actor PushAttestRecorder {
    private var generatedKeys: [String]
    private var assertionResults: [Result<Data, NSError>]
    private(set) var generatedCount = 0
    private(set) var assertionKeys: [String] = []

    init(
        generatedKeys: [String] = ["generated-key"],
        assertionResults: [Result<Data, NSError>] = []
    ) {
        self.generatedKeys = generatedKeys
        self.assertionResults = assertionResults
    }

    nonisolated var client: PushAppAttestClient {
        PushAppAttestClient(
            isSupported: { true },
            generateKey: { try await self.generate() },
            attest: { _, _ in Data("attestation".utf8) },
            assert: { key, _ in try await self.assertion(key: key) }
        )
    }

    private func generate() throws -> String {
        generatedCount += 1
        guard !generatedKeys.isEmpty else { throw PushRegistrationError.unavailable }
        return generatedKeys.removeFirst()
    }

    private func assertion(key: String) throws -> Data {
        assertionKeys.append(key)
        guard !assertionResults.isEmpty else { return Data("assertion".utf8) }
        return try assertionResults.removeFirst().get()
    }
}

private actor PushRetryRecorder {
    private(set) var values: [Duration] = []
    func append(_ duration: Duration) { values.append(duration) }
}

private actor PushCancellationProbe {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor PushRequestLog {
    private(set) var requests: [URLRequest] = []
    private(set) var maximumBytes: [Int] = []
    func append(_ request: URLRequest, maximumBytes: Int) {
        requests.append(request)
        self.maximumBytes.append(maximumBytes)
    }
}
