import Foundation
import Testing
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
    }

    @Test("registration payload has stable bounded canonical bytes")
    func canonicalRegistration() throws {
        let payload = PushWorkerClient.RegistrationPayload(
            version: 1,
            challengeId: "challenge-id",
            challenge: "challenge",
            keyId: "key-id",
            apnsToken: "0102ff",
            environment: .sandbox,
            bindingHash: "binding"
        )
        let data = try PushWorkerClient.canonicalData(payload)
        #expect(String(decoding: data, as: UTF8.self) == #"{"apnsToken":"0102ff","bindingHash":"binding","challenge":"challenge","challengeId":"challenge-id","environment":"sandbox","keyId":"key-id","version":1}"#)
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
                body = #"{"installationId":"installation_1","grantId":"grant_1","grantSecret":"0123456789abcdef0123456789abcdef"}"#
            }
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
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
        #expect(grant.environment == .sandbox)
        #expect(store.value?.apnsToken == "0102ff")
        let requests = await requestLog.requests
        #expect(requests.map { $0.url?.path } == ["/v3/attestation/challenge", "/v3/installations"])
        #expect(requests.allSatisfy { $0.url?.host == "push.example.test" })
        let responseBounds = await requestLog.maximumBytes
        #expect(responseBounds.allSatisfy { $0 == 16 * 1024 })
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
    private var supportedAttest: PushAppAttestClient {
        PushAppAttestClient(
            isSupported: { true },
            generateKey: { "unused" },
            attest: { _, _ in Data() },
            assert: { _, _ in Data() }
        )
    }
}

private final class MemoryPushCredentialStore: PushCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PushCredentialDocument?
    var value: PushCredentialDocument? { lock.withLock { stored } }
    func load() throws -> PushCredentialDocument? { value }
    func save(_ document: PushCredentialDocument) throws { lock.withLock { stored = document } }
}

private actor PushRequestLog {
    private(set) var requests: [URLRequest] = []
    private(set) var maximumBytes: [Int] = []
    func append(_ request: URLRequest, maximumBytes: Int) {
        requests.append(request)
        self.maximumBytes.append(maximumBytes)
    }
}
