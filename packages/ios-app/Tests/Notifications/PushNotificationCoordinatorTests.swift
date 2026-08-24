import CryptoKit
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
