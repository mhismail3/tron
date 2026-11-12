import Foundation
@testable import TronMobile
@testable import TronMobileCore
import XCTest

@MainActor
final class PushRegistrationRetryTests: XCTestCase {
    private struct UnreachableSocket: GatewaySocketConnection {
        func send(_ data: Data) async throws { throw CancellationError() }
        func receive() async throws -> Data { throw CancellationError() }
        func ping() async throws { throw CancellationError() }
        func close() async {}
    }

    private struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    private final class CredentialMemory: PushCredentialStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var document: PushCredentialDocument?
        private var saves = 0

        init(_ document: PushCredentialDocument?) { self.document = document }

        func load() throws -> PushCredentialDocument? { lock.withLock { document } }
        func save(_ document: PushCredentialDocument) throws { lock.withLock { self.document = document; saves += 1 } }
        var saveCount: Int { lock.withLock { saves } }
    }

    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var requestPaths: [String] = []
        private var generated: [String] = []
        private var attested: [String] = []

        func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw URLError(.badURL) }
            let isChallenge = url.path == "/v3/attestation/challenge"
            lock.withLock { requestPaths.append(url.path) }
            let body = isChallenge
                ? Data(#"{"challengeId":"challenge-000001","challenge":"challenge-body-000001","expiresAt":"2026-11-12T20:00:00Z"}"#.utf8)
                : Data("{}".utf8)
            guard let response = HTTPURLResponse(url: url, statusCode: isChallenge ? 200 : 401, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (body, response)
        }

        func nextKey() -> String {
            lock.withLock {
                let key = Self.key(100 + generated.count)
                generated.append(key)
                return key
            }
        }

        func recordAttestation(_ keyID: String) {
            lock.withLock { attested.append(keyID) }
        }

        func count(path: String) -> Int { lock.withLock { requestPaths.filter { $0 == path }.count } }
        var keysGenerated: Int { lock.withLock { generated.count } }
        var attestedKeys: [String] { lock.withLock { attested } }

        static func key(_ index: Int) -> String {
            Data(repeating: UInt8(index % 251), count: 32).base64EncodedString()
        }
    }

    private static let profile = GatewayProfile(
        id: "profile-a", label: "Mac A", host: "push-test.example.com", port: 9848,
        machineId: "machine-a", deviceId: "device-a"
    )
    private static let retryCard = """
    {"digest":"\(String(repeating: "a", count: 64))","title":"Retry push registration","requiresTap":true,\
    "reason":"Alerts stopped","intent":"push-registration-retry",\
    "items":[{"label":"Push registration","before":"Stopped","after":"Retried once on this iPhone"}]}
    """

    private struct Harness {
        let coordinator: PushNotificationCoordinator
        let credentials: CredentialMemory
        let ledger: Ledger
    }

    private func makeHarness() throws -> Harness {
        let rejected = PushCredentialDocument(
            appAttestKeyID: Ledger.key(1),
            apnsToken: String(repeating: "ab", count: 32),
            grants: [:],
            appAttestKeyRejected: true
        )
        let credentials = CredentialMemory(rejected)
        let ledger = Ledger()
        let appAttest = PushAppAttestClient(
            isSupported: { true },
            generateKey: { ledger.nextKey() },
            attest: { keyID, _ in ledger.recordAttestation(keyID); return Data([1]) },
            assert: { _, _ in Data([2]) }
        )
        let coordinator = PushNotificationCoordinator(
            credentials: credentials,
            notifications: PushNotificationSystem(
                authorization: { .allowed },
                requestAuthorization: { true },
                registerForRemoteNotifications: {}
            ),
            appAttest: appAttest,
            configuration: try XCTUnwrap(PushProductConfiguration.admit(URL(string: "https://push.example.com")!)),
            transport: BoundedHTTPDataTransport(dataForRequest: { request, _ in try ledger.respond(request) })
        )
        return Harness(coordinator: coordinator, credentials: credentials, ledger: ledger)
    }

    private func reconcile(_ harness: Harness, profile: GatewayProfile = PushRegistrationRetryTests.profile, epoch: String = "epoch-1") async {
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in UnreachableSocket() })
        await harness.coordinator.reconcile(
            profile: profile, connected: true, gatewayRuntimeEpoch: epoch, client: client
        )
    }

    private func eventually(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw WaitTimeout(description: message)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func retryCardReview() throws -> ChangeReview {
        try JSONDecoder().decode(ChangeReview.self, from: Data(Self.retryCard.utf8))
    }

    private func stoppedAfterAutomaticRetry() async throws -> Harness {
        let harness = try makeHarness()
        await reconcile(harness)
        try await eventually("the one automatic rejected-key retry finishes") {
            harness.ledger.count(path: "/v3/installations") == 1
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "the automatic retry generates exactly one key")
        return harness
    }

    func testRetryCardRotatesOnceAfterAcceptedTapAndDuplicateApprovalDoesNot() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let fence = try XCTUnwrap(harness.coordinator.retryFence(for: try retryCardReview()))
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "presenting the card rotates nothing")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1, "presenting the card registers nothing")
        let savesBeforeAcceptance = harness.credentials.saveCount

        try harness.coordinator.retryAfterApprovedCard(fence)
        XCTAssertThrowsError(try harness.coordinator.retryAfterApprovedCard(fence), "a duplicate approval must not rotate again")

        try await eventually("the accepted card's single attempt is rejected once more") {
            harness.ledger.count(path: "/v3/installations") == 2
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 2, "exactly one fresh key after the accepted card")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 2, "no automatic chain after the card attempt")
        let attested = harness.ledger.attestedKeys
        XCTAssertEqual(attested.count, 2)
        if attested.count == 2 {
            XCTAssertNotEqual(attested[0], attested[1], "the card attempt proves with the fresh key")
        }
        XCTAssertGreaterThan(harness.credentials.saveCount, savesBeforeAcceptance)
    }

    func testStaleProfileCannotRotateTheCurrentKey() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let fence = try XCTUnwrap(harness.coordinator.retryFence(for: try retryCardReview()))
        let other = GatewayProfile(
            id: "profile-b", label: "Mac B", host: "push-test.example.com", port: 9848,
            machineId: "machine-b", deviceId: "device-b"
        )
        await reconcile(harness, profile: other)
        try await settle()
        XCTAssertThrowsError(try harness.coordinator.retryAfterApprovedCard(fence))
        XCTAssertEqual(harness.ledger.keysGenerated, 1)
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1)
    }

    func testStaleConnectionCannotRotateTheCurrentKey() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let fence = try XCTUnwrap(harness.coordinator.retryFence(for: try retryCardReview()))
        await reconcile(harness, epoch: "epoch-2")
        try await settle()
        XCTAssertThrowsError(try harness.coordinator.retryAfterApprovedCard(fence))
        XCTAssertEqual(harness.ledger.keysGenerated, 1)
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1)
    }

    func testOnlyAPushRetryCardWithATapYieldsAFence() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let withoutIntent = try JSONDecoder().decode(ChangeReview.self, from: Data(
            Self.retryCard.replacingOccurrences(of: #","intent":"push-registration-retry""#, with: "").utf8))
        XCTAssertNil(harness.coordinator.retryFence(for: withoutIntent))
        let withoutTap = try JSONDecoder().decode(ChangeReview.self, from: Data(
            Self.retryCard.replacingOccurrences(of: #""requiresTap":true"#, with: #""requiresTap":false"#).utf8))
        XCTAssertNil(harness.coordinator.retryFence(for: withoutTap))
        XCTAssertEqual(harness.ledger.keysGenerated, 1)
    }
}
