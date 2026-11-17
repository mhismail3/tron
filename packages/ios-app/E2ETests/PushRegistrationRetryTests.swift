import DeviceCheck
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
        private var scriptedStatuses: [Int]

        init(installationStatuses: [Int] = []) { scriptedStatuses = installationStatuses }

        func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw URLError(.badURL) }
            let isChallenge = url.path == "/v3/attestation/challenge"
            lock.withLock { requestPaths.append(url.path) }
            let body = isChallenge
                ? Data(#"{"challengeId":"challenge-000001","challenge":"challenge-body-000001","expiresAt":"2026-11-12T20:00:00Z"}"#.utf8)
                : Data("{}".utf8)
            let status = isChallenge ? 200 : lock.withLock { scriptedStatuses.isEmpty ? 401 : scriptedStatuses.removeFirst() }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
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

    private final class ConnectionBox: @unchecked Sendable {
        var current: PushConnectionIdentity?
    }

    private final class AnswerCounter: @unchecked Sendable {
        var accepted = 0
        var attempted = 0
    }

    private static let profileA = GatewayProfile(
        id: "profile-a", label: "Mac A", host: "push-test.example.com", port: 9848,
        machineId: "machine-a", deviceId: "device-a"
    )
    private static let profileB = GatewayProfile(
        id: "profile-b", label: "Mac B", host: "push-test.example.com", port: 9848,
        machineId: "machine-b", deviceId: "device-b"
    )
    private static let retryCard = """
    {"digest":"\(String(repeating: "a", count: 64))","title":"Retry push registration","requiresTap":true,\
    "reason":"Alerts stopped","intent":"push-registration-retry",\
    "items":[{"label":"Push registration","before":"Stopped","after":"Requested"}]}
    """

    private struct Harness: @unchecked Sendable {
        let coordinator: PushNotificationCoordinator
        let credentials: CredentialMemory
        let ledger: Ledger
        let connection: ConnectionBox
        let gate: PushRegistrationRetryApproval
    }

    private func makeHarness(flagged: Bool, assertionInvalidKey: Bool = false, installationStatuses: [Int] = []) throws -> Harness {
        let credentials = CredentialMemory(PushCredentialDocument(
            appAttestKeyID: Ledger.key(1),
            apnsToken: String(repeating: "ab", count: 32),
            grants: [:],
            appAttestKeyRejected: flagged ? true : nil
        ))
        let ledger = Ledger(installationStatuses: installationStatuses)
        let appAttest = PushAppAttestClient(
            isSupported: { true },
            generateKey: { ledger.nextKey() },
            attest: { keyID, _ in ledger.recordAttestation(keyID); return Data([1]) },
            assert: { _, _ in
                if assertionInvalidKey {
                    throw NSError(domain: DCError.errorDomain, code: DCError.Code.invalidKey.rawValue)
                }
                return Data([2])
            }
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
        let connection = ConnectionBox()
        let gate = PushRegistrationRetryApproval(connection: { connection.current }, coordinator: coordinator)
        return Harness(coordinator: coordinator, credentials: credentials, ledger: ledger, connection: connection, gate: gate)
    }

    private func identity(_ profile: GatewayProfile, epoch: String = "epoch-1", admission: Int = 1) -> PushConnectionIdentity {
        PushConnectionIdentity(
            profileID: profile.id,
            machineID: profile.machineId,
            runtimeEpoch: epoch,
            admission: GatewayLifecycleCoordinator.Admission(generation: admission, connectionID: admission)
        )
    }

    private func connect(
        _ harness: Harness,
        profile: GatewayProfile = PushRegistrationRetryTests.profileA,
        epoch: String = "epoch-1",
        admission: Int = 1
    ) async {
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in UnreachableSocket() })
        await harness.coordinator.reconcile(profile: profile, connected: true, gatewayRuntimeEpoch: epoch, client: client)
        harness.connection.current = identity(profile, epoch: epoch, admission: admission)
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

    private func answerOnce(_ counter: AnswerCounter) -> PushRetryAnswer {
        {
            counter.attempted += 1
            guard counter.accepted == 0 else { throw GatewayFailure(code: "not_found", message: "Extension interaction is no longer pending", retryable: false, details: nil) }
            counter.accepted += 1
        }
    }

    private func stoppedAfterAutomaticRetry() async throws -> Harness {
        let harness = try makeHarness(flagged: true)
        await connect(harness)
        try await eventually("the one automatic rejected-key retry finishes") {
            harness.ledger.count(path: "/v3/installations") == 1
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "the automatic retry generates exactly one key")
        return harness
    }

    func testRetryCardRotatesOnceAfterAcceptedTapAndDuplicateApprovalDoesNot() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let card = try retryCardReview()
        let counter = AnswerCounter()
        let savesBeforeCapture = harness.credentials.saveCount
        _ = try XCTUnwrap(harness.coordinator.retryFence(for: card, connection: try XCTUnwrap(harness.connection.current)))
        XCTAssertEqual(harness.credentials.saveCount, savesBeforeCapture, "capturing the fence writes nothing")
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "presenting the card rotates nothing")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1, "presenting the card registers nothing")
        XCTAssertEqual(counter.attempted, 0, "presenting the card answers nothing")

        try await harness.gate.approve(card, answer: answerOnce(counter))
        XCTAssertEqual(counter.accepted, 1)
        await XCTAssertThrowsErrorAsync(try await harness.gate.approve(card, answer: answerOnce(counter)))
        XCTAssertEqual(counter.attempted, 2, "the duplicate reached the answer boundary and was refused there")

        try await eventually("the accepted card's single attempt is rejected once more") {
            harness.ledger.count(path: "/v3/installations") == 2
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 2, "exactly one fresh key after the accepted card")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 2, "no automatic chain after the card attempt")
        XCTAssertEqual(harness.ledger.attestedKeys.count, 2)
        if harness.ledger.attestedKeys.count == 2 {
            XCTAssertNotEqual(harness.ledger.attestedKeys[0], harness.ledger.attestedKeys[1], "the card attempt proves with the fresh key")
        }
    }

    func testPresentedConnectionMismatchRefusesBeforeAnswer() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let card = try retryCardReview()
        let counter = AnswerCounter()

        harness.connection.current = identity(Self.profileB, admission: 2)
        await XCTAssertThrowsErrorAsync(try await harness.gate.approve(card, answer: answerOnce(counter)))
        XCTAssertEqual(counter.attempted, 0, "a card presented for another connection is never answered")

        await connect(harness, profile: Self.profileB, admission: 3)
        harness.connection.current = identity(Self.profileA, admission: 3)
        await XCTAssertThrowsErrorAsync(try await harness.gate.approve(card, answer: answerOnce(counter)))
        XCTAssertEqual(counter.attempted, 0, "a coordinator for B never answers for a connected A")
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1)
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1)
    }

    func testConnectionChangeAfterAcceptanceRefusesRotation() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let card = try retryCardReview()
        let counter = AnswerCounter()
        let answer: PushRetryAnswer = { [self] in
            try await self.answerOnce(counter)()
            harness.connection.current = self.identity(Self.profileA, epoch: "epoch-2", admission: 2)
        }
        await XCTAssertThrowsErrorAsync(try await harness.gate.approve(card, answer: answer))
        XCTAssertEqual(counter.accepted, 1, "the accepted answer is not undone")
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "a runtime change after acceptance rotates nothing")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1)
    }

    func testUnflaggedStoredKeyRejectedInAssertionRotatesExactlyOnce() async throws {
        let harness = try makeHarness(flagged: false)
        await connect(harness)
        try await eventually("the in-loop rotation and its rejection settle") {
            harness.coordinator.diagnostic == .stoppedRejected
        }
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "one launch rotates one key: the in-loop assertion rotation")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 2, "assertion then attestation, then no chain")
        XCTAssertEqual(harness.ledger.attestedKeys.count, 1)
        XCTAssertGreaterThan(harness.credentials.saveCount, 0)
    }

    func testInvalidKeyAssertionRecoveryConsumesTheOneLaunchBudget() async throws {
        let harness = try makeHarness(flagged: false, assertionInvalidKey: true)
        await connect(harness)
        try await eventually("the invalid-key recovery and its rejection settle") {
            harness.ledger.count(path: "/v3/installations") >= 1
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "one launch generates one fresh key: the invalid-key recovery, with no second automatic rotation")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 1, "one registration attempt with the fresh key, then no chain")
        XCTAssertEqual(harness.coordinator.diagnostic, .stoppedRejected)
        XCTAssertGreaterThan(harness.credentials.saveCount, 0)
    }

    func testTransientAttestationThenAssertionRejectionStopsWithCardEligibleKey() async throws {
        let harness = try makeHarness(flagged: true, installationStatuses: [503, 401, 503, 401])
        await connect(harness)
        try await eventually("the transient attestation retry ends at its one assertion rejection") {
            harness.ledger.count(path: "/v3/installations") == 2
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 1, "the flagged key rotates once; the 503 retry and the assertion 401 spend no second rotation")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 2, "one attestation that fails transiently, one assertion that is rejected, then no chain")
        XCTAssertEqual(try XCTUnwrap(harness.credentials.load()).appAttestKeyRejected, true)

        let card = try retryCardReview()
        _ = try XCTUnwrap(harness.coordinator.retryFence(for: card, connection: try XCTUnwrap(harness.connection.current)))
        let counter = AnswerCounter()
        try await harness.gate.approve(card, answer: answerOnce(counter))
        XCTAssertEqual(counter.accepted, 1)
        try await eventually("the accepted card makes its single fresh attempt") {
            harness.ledger.count(path: "/v3/installations") == 4
                && harness.coordinator.diagnostic == .stoppedRejected
        }
        try await settle()
        XCTAssertEqual(harness.ledger.keysGenerated, 2, "the accepted card rotates exactly once more")
        XCTAssertEqual(harness.ledger.count(path: "/v3/installations"), 4, "the card also stops after its transient attestation and assertion rejection")
        XCTAssertEqual(try XCTUnwrap(harness.credentials.load()).appAttestKeyRejected, true)
    }

    func testOnlyAPushRetryCardWithATapYieldsAFence() async throws {
        let harness = try await stoppedAfterAutomaticRetry()
        let current = try XCTUnwrap(harness.connection.current)
        let withoutIntent = try JSONDecoder().decode(ChangeReview.self, from: Data(
            Self.retryCard.replacingOccurrences(of: #","intent":"push-registration-retry""#, with: "").utf8))
        XCTAssertNil(harness.coordinator.retryFence(for: withoutIntent, connection: current))
        let withoutTap = try JSONDecoder().decode(ChangeReview.self, from: Data(
            Self.retryCard.replacingOccurrences(of: #""requiresTap":true"#, with: #""requiresTap":false"#).utf8))
        XCTAssertNil(harness.coordinator.retryFence(for: withoutTap, connection: current))
        XCTAssertEqual(harness.ledger.keysGenerated, 1)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
