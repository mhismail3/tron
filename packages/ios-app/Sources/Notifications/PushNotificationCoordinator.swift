import CryptoKit
import DeviceCheck
import Foundation
import Observation
import Security
import UIKit
import UserNotifications

enum PushRoute: String, Codable, Sendable {
    case beta
    case productionSandbox = "production-sandbox"
    case production

    static var current: Self {
        #if BETA
        .beta
        #elseif DEBUG
        .productionSandbox
        #else
        .production
        #endif
    }
}

enum PushReadiness: Equatable, Sendable {
    case unavailable
    case permissionRequired
    case denied
    case registering
    case ready
    case pending
}

/// Fixed, privacy-safe registration stages for local troubleshooting. Values
/// deliberately contain no service, device, profile, credential, or proof data.
enum PushRegistrationDiagnostic: String, Equatable, Sendable {
    case idle = "Idle"
    case waitingForToken = "Waiting for APNs"
    case requestingChallenge = "Requesting challenge"
    case generatingKey = "Generating App Attest key"
    case generatingAttestation = "Generating attestation"
    case generatingAssertion = "Generating assertion"
    case submittingProof = "Submitting proof"
    case retryBackoff = "Retry backoff"
    case transferringGrant = "Transferring grant"
    case complete = "Complete"
    case stoppedRejected = "Stopped: rejected"
    case stoppedInvalidKey = "Stopped: invalid key"
    case stoppedInvalidResponse = "Stopped: invalid response"
    case stoppedPersistence = "Stopped: credential storage"
    case stoppedExhausted = "Stopped: retry limit"
    case stoppedUnavailable = "Stopped: unavailable"
}

struct PushGrant: Codable, Equatable, Sendable {
    let profileID: String
    let installationID: String
    let grantID: String
    let grantSecret: String
    let tokenHash: String
}

struct PushCredentialDocument: Codable, Equatable, Sendable {
    var appAttestKeyID: String?
    var apnsToken: String?
    var grants: [String: PushGrant]
    /// A fresh attestation was definitively rejected. Keep its key for
    /// diagnostics, but do not reinterpret it as an assertion key on reconcile.
    var appAttestKeyRejected: Bool? = nil

    static let empty = PushCredentialDocument(appAttestKeyID: nil, apnsToken: nil, grants: [:])
}

protocol PushCredentialStoring: Sendable {
    func load() throws -> PushCredentialDocument?
    func save(_ document: PushCredentialDocument) throws
}

struct KeychainPushCredentialStore: PushCredentialStoring {
    private let service = "com.tron.mobile.push.v1"
    private let account = "installation"

    func load() throws -> PushCredentialDocument? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainPushError(status: status) }
        guard data.count <= 32 * 1024 else { throw PushRegistrationError.invalidCredentialState }
        return try JSONDecoder().decode(PushCredentialDocument.self, from: data)
    }

    func save(_ document: PushCredentialDocument) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= 32 * 1024 else { throw PushRegistrationError.invalidCredentialState }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainPushError(status: update) }
        let add = SecItemAdd(identity.merging(values) { _, value in value } as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainPushError(status: add) }
    }
}

struct KeychainPushError: Error { let status: OSStatus }

enum PushAuthorization: Equatable, Sendable {
    case notDetermined, denied, allowed
}

struct PushNotificationSystem: Sendable {
    let authorization: @Sendable () async -> PushAuthorization
    let requestAuthorization: @Sendable () async throws -> Bool
    let registerForRemoteNotifications: @MainActor @Sendable () -> Void

    static let live = PushNotificationSystem(
        authorization: {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized, .provisional, .ephemeral: return .allowed
            @unknown default: return .denied
            }
        },
        requestAuthorization: {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        },
        registerForRemoteNotifications: {
            UIApplication.shared.registerForRemoteNotifications()
        }
    )
}

struct PushAppAttestClient: @unchecked Sendable {
    let isSupported: @Sendable () -> Bool
    let generateKey: @Sendable () async throws -> String
    let attest: @Sendable (String, Data) async throws -> Data
    let assert: @Sendable (String, Data) async throws -> Data

    static let live = PushAppAttestClient(
        isSupported: { DCAppAttestService.shared.isSupported },
        generateKey: { try await DCAppAttestService.shared.generateKey() },
        attest: { keyID, hash in try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash) },
        assert: { keyID, hash in try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash) }
    )
}

struct PushProductConfiguration: Equatable, Sendable {
    let origin: URL

    static func bundled(_ bundle: Bundle = .main) -> PushProductConfiguration? {
        guard let raw = bundle.object(forInfoDictionaryKey: "TRONPushServiceOrigin") as? String,
              let url = URL(string: raw) else { return nil }
        return admit(url)
    }

    static func admit(_ url: URL) -> PushProductConfiguration? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil,
              url.path.isEmpty || url.path == "/",
              host.utf8.count <= 253, host.contains("."), host != "localhost",
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.contains(":"), !host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(Self.isPublicDNSLabel) else { return nil }
        return PushProductConfiguration(origin: url)
    }

    private static func isPublicDNSLabel(_ label: Substring) -> Bool {
        let bytes = Array(label.utf8)
        guard !bytes.isEmpty, bytes.count <= 63 else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        return alphanumeric(bytes[0]) && alphanumeric(bytes[bytes.count - 1])
            && bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
    }

    func endpoint(_ path: String) -> URL {
        origin.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

enum PushRegistrationError: Error {
    case unavailable
    case invalidConfiguration
    case invalidCredentialState
    case invalidResponse
    case rejected(Int)
    case persistence
    case invalidAppAttestKey
    case retryExhausted
}

struct PushWorkerClient: Sendable {
    struct Challenge: Decodable, Sendable {
        let challengeId: String
        let challenge: String
        let expiresAt: String
    }

    struct RegistrationPayload: Codable, Equatable, Sendable {
        let version: Int
        let challengeId: String
        let challenge: String
        let keyId: String
        let apnsToken: String
        let route: PushRoute
        let bindingHash: String
    }

    private struct RegistrationRequest: Encodable, Sendable {
        let version: Int
        let proof: String
        let challengeId: String
        let challenge: String
        let keyId: String
        let apnsToken: String
        let route: PushRoute
        let bindingHash: String
        let attestationObject: String?
        let assertionObject: String?

        enum CodingKeys: String, CodingKey {
            case version, proof, challengeId, challenge, keyId, apnsToken, route, bindingHash, attestationObject, assertionObject
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(proof, forKey: .proof)
            try container.encode(challengeId, forKey: .challengeId)
            try container.encode(challenge, forKey: .challenge)
            try container.encode(keyId, forKey: .keyId)
            try container.encode(apnsToken, forKey: .apnsToken)
            try container.encode(route, forKey: .route)
            try container.encode(bindingHash, forKey: .bindingHash)
            if let attestationObject { try container.encode(attestationObject, forKey: .attestationObject) }
            if let assertionObject { try container.encode(assertionObject, forKey: .assertionObject) }
        }
    }

    struct RegistrationResponse: Decodable, Sendable {
        let installationId: String
        let grantId: String
        let grantSecret: String
        let route: PushRoute
    }

    private let configuration: PushProductConfiguration
    private let transport: BoundedHTTPDataTransport

    init(configuration: PushProductConfiguration, transport: BoundedHTTPDataTransport = .pushService) {
        self.configuration = configuration
        self.transport = transport
    }

    func challenge() async throws -> Challenge {
        try await post(path: "/v3/attestation/challenge", body: Optional<Data>.none, acceptedStatus: 200, as: Challenge.self)
    }

    func register(
        payload: RegistrationPayload,
        mode: String,
        proof: Data
    ) async throws -> RegistrationResponse {
        guard mode == "attestation" || mode == "assertion" else { throw PushRegistrationError.invalidResponse }
        let encodedProof = proof.base64URLEncodedString()
        let request = RegistrationRequest(
            version: 1, proof: mode,
            challengeId: payload.challengeId, challenge: payload.challenge,
            keyId: payload.keyId, apnsToken: payload.apnsToken,
            route: payload.route, bindingHash: payload.bindingHash,
            attestationObject: mode == "attestation" ? encodedProof : nil,
            assertionObject: mode == "assertion" ? encodedProof : nil
        )
        return try await post(path: "/v3/installations", body: request, acceptedStatus: 201, as: RegistrationResponse.self)
    }

    static func canonicalData(_ payload: RegistrationPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard data.count <= 8 * 1024 else { throw PushRegistrationError.invalidResponse }
        return data
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body?,
        acceptedStatus: Int,
        as type: Response.Type
    ) async throws -> Response {
        // The one-time App Attest installation carries a certificate chain and
        // crosses the Durable Object verification boundary. Keep ordinary
        // challenge admission tight while allowing that non-blocking bootstrap
        // to finish on a cold mobile/Worker path.
        let timeout: TimeInterval = path == "/v3/installations" ? 60 : 15
        var request = URLRequest(url: configuration.endpoint(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
            guard let bodySize = request.httpBody?.count, bodySize <= 16 * 1024 else { throw PushRegistrationError.invalidResponse }
        }
        let (data, response) = try await transport.data(for: request, maximumBytes: 16 * 1024)
        guard response.url == request.url,
              response.statusCode == acceptedStatus else {
            throw PushRegistrationError.rejected(response.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct PushRegistrationTransfer: Encodable, Sendable {
    let commandId: String
    let installationId: String
    let grantId: String
    let secret: String
    let previewsEnabled: Bool
}

private struct PushRegistrationRemoval: Encodable, Sendable { let commandId: String }
struct PushRegistrationStatus: Decodable, Sendable {
    let available: Bool
    let registered: Bool
    let deviceRegistered: Bool
    let enabledDeviceCount: Int
    let pendingCount: Int
    let notifyWhenAskPresented: Bool
}
private struct PushRegistrationRemovalResult: Decodable, Sendable { let removed: Bool }

@MainActor
@Observable
final class PushNotificationCoordinator {
    private struct Context: Sendable {
        let profile: GatewayProfile
        let client: GatewayClient
    }

    private let credentials: any PushCredentialStoring
    private let notifications: PushNotificationSystem
    private let appAttest: PushAppAttestClient
    private let worker: PushWorkerClient?
    private let uuid: @Sendable () -> UUID
    private let clock: MonotonicClock
    private let credentialLoadFailed: Bool
    private var document: PushCredentialDocument
    private var context: Context?
    private var registrationTask: Task<Void, Never>?
    private var registrationGeneration = 0

    private(set) var readiness: PushReadiness = .unavailable
    private(set) var diagnostic: PushRegistrationDiagnostic = .idle

    convenience init() {
        self.init(
            credentials: KeychainPushCredentialStore(),
            notifications: .live,
            appAttest: .live,
            configuration: PushProductConfiguration.bundled()
        )
    }

    init(
        credentials: any PushCredentialStoring,
        notifications: PushNotificationSystem,
        appAttest: PushAppAttestClient,
        configuration: PushProductConfiguration?,
        transport: BoundedHTTPDataTransport = .pushService,
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        clock: MonotonicClock = .continuous
    ) {
        self.credentials = credentials
        self.notifications = notifications
        self.appAttest = appAttest
        self.worker = configuration.map { PushWorkerClient(configuration: $0, transport: transport) }
        self.uuid = uuid
        self.clock = clock
        do {
            self.document = try credentials.load() ?? .empty
            self.credentialLoadFailed = false
        } catch {
            // Never overwrite an unreadable Keychain document with an empty
            // replacement. The ordinary Gateway remains usable while push fails closed.
            self.document = .empty
            self.credentialLoadFailed = true
        }
    }

    func reconcile(profile: GatewayProfile?, connected: Bool, client: GatewayClient) async {
        guard let profile else {
            registrationGeneration &+= 1
            registrationTask?.cancel()
            registrationTask = nil
            context = nil
            readiness = .unavailable
            diagnostic = .idle
            return
        }
        if context?.profile.id != profile.id {
            registrationGeneration &+= 1
            registrationTask?.cancel()
            registrationTask = nil
        }
        context = Context(profile: profile, client: client)
        guard !credentialLoadFailed, worker != nil, appAttest.isSupported() else {
            readiness = .unavailable
            diagnostic = .stoppedUnavailable
            return
        }

        var status = await notifications.authorization()
        if status == .notDetermined {
            readiness = .permissionRequired
            do {
                status = try await notifications.requestAuthorization() ? .allowed : .denied
            } catch {
                readiness = .pending
                return
            }
        }
        guard status == .allowed else {
            readiness = .denied
            diagnostic = .idle
            if connected { await removeRegistration(for: profile, client: client) }
            return
        }

        if let grant = document.grants[profile.id], connected {
            readiness = await transfer(grant, client: client) ? .ready : .pending
        }
        notifications.registerForRemoteNotifications()
        guard document.apnsToken != nil else {
            if document.grants[profile.id] == nil { readiness = .registering }
            diagnostic = .waitingForToken
            return
        }
        scheduleRegistration()
    }

    func receiveDeviceToken(_ token: Data) {
        guard !credentialLoadFailed, !token.isEmpty, token.count <= 256 else { return }
        let encoded = token.map { String(format: "%02x", $0) }.joined()
        if document.apnsToken != encoded {
            registrationGeneration &+= 1
            registrationTask?.cancel()
            registrationTask = nil
        }
        var updated = document
        updated.apnsToken = encoded
        do { try credentials.save(updated) }
        catch {
            readiness = .pending
            diagnostic = .stoppedPersistence
            return
        }
        document = updated
        scheduleRegistration()
    }

    func receiveRegistrationFailure() {
        readiness = .pending
        diagnostic = .stoppedUnavailable
    }

    private func scheduleRegistration() {
        guard registrationTask == nil, context != nil, document.apnsToken != nil else { return }
        readiness = .registering
        registrationGeneration &+= 1
        let generation = registrationGeneration
        registrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.registrationGeneration == generation { self.registrationTask = nil }
            }
            do { try await self.registerCurrent(generation: generation) }
            catch is CancellationError { return }
            catch let error as PushRegistrationError {
                self.readiness = .pending
                self.diagnostic = Self.diagnostic(for: error)
            } catch {
                self.readiness = .pending
                self.diagnostic = .stoppedUnavailable
            }
        }
    }

    private enum ProofMode: String { case attestation, assertion }
    private static let retryBackoffs: [Duration] = [.milliseconds(250), .milliseconds(750)]

    /// One bounded operation owns all proof recovery. Every retry starts with a
    /// fresh challenge and generates a fresh proof; neither value is replayed.
    private func registerCurrent(generation: Int) async throws {
        guard let admittedContext = context, let worker, let token = document.apnsToken else {
            throw PushRegistrationError.unavailable
        }
        try validateRegistration(generation: generation, profileID: admittedContext.profile.id, token: token)
        let tokenHash = Self.hash("tron-apns-token-v1\0" + token)
        if let grant = document.grants[admittedContext.profile.id], grant.tokenHash == tokenHash {
            diagnostic = .transferringGrant
            readiness = await transfer(grant, client: admittedContext.client) ? .ready : .pending
            diagnostic = readiness == .ready ? .complete : .stoppedUnavailable
            return
        }

        if document.appAttestKeyID != nil, document.appAttestKeyRejected == true {
            throw PushRegistrationError.rejected(401)
        }
        var mode: ProofMode = document.appAttestKeyID == nil ? .attestation : .assertion
        var recoveredInvalidKey = false
        var retryIndex = 0

        while true {
            try validateRegistration(generation: generation, profileID: admittedContext.profile.id, token: token)
            do {
                diagnostic = .requestingChallenge
                let challenge = try await worker.challenge()
                try validateRegistration(generation: generation, profileID: admittedContext.profile.id, token: token)
                guard challenge.challengeId.utf8.count <= 160,
                      challenge.challenge.utf8.count <= 512,
                      !challenge.challengeId.isEmpty,
                      !challenge.challenge.isEmpty else { throw PushRegistrationError.invalidResponse }

                var keyID = document.appAttestKeyID
                if keyID == nil {
                    diagnostic = .generatingKey
                    keyID = try await appAttest.generateKey()
                    try validateRegistration(generation: generation, profileID: admittedContext.profile.id, token: token)
                    try persistAppAttestKeyID(keyID, rejected: false)
                    mode = .attestation
                }
                guard let keyID, !keyID.isEmpty, keyID.utf8.count <= 512 else {
                    throw PushRegistrationError.invalidCredentialState
                }
                let bindingHash = Self.hash(
                    "tron-push-binding-v1\0\(admittedContext.profile.machineId)\0\(admittedContext.profile.deviceId)"
                )
                let payload = PushWorkerClient.RegistrationPayload(
                    version: 1,
                    challengeId: challenge.challengeId,
                    challenge: challenge.challenge,
                    keyId: keyID,
                    apnsToken: token,
                    route: .current,
                    bindingHash: bindingHash
                )
                let clientDataHash = Data(SHA256.hash(data: try PushWorkerClient.canonicalData(payload)))
                let proof: Data
                do {
                    diagnostic = mode == .attestation ? .generatingAttestation : .generatingAssertion
                    proof = mode == .attestation
                        ? try await appAttest.attest(keyID, clientDataHash)
                        : try await appAttest.assert(keyID, clientDataHash)
                } catch {
                    guard mode == .assertion, Self.isInvalidAppAttestKey(error), !recoveredInvalidKey else {
                        if Self.isInvalidAppAttestKey(error) { throw PushRegistrationError.invalidAppAttestKey }
                        throw error
                    }
                    try rotateInvalidKey()
                    recoveredInvalidKey = true
                    mode = .attestation
                    continue
                }
                try validateRegistration(generation: generation, profileID: admittedContext.profile.id, token: token)
                diagnostic = .submittingProof
                do {
                    let response = try await worker.register(payload: payload, mode: mode.rawValue, proof: proof)
                    try validateRegistration(
                        generation: generation,
                        profileID: admittedContext.profile.id,
                        token: token
                    )
                    guard response.route == payload.route,
                          Self.isOpaqueID(response.installationId),
                          Self.isOpaqueID(response.grantId),
                          response.grantSecret.utf8.count >= 32,
                          response.grantSecret.utf8.count <= 512 else {
                        throw PushRegistrationError.invalidResponse
                    }
                    let grant = PushGrant(
                        profileID: admittedContext.profile.id,
                        installationID: response.installationId,
                        grantID: response.grantId,
                        grantSecret: response.grantSecret,
                        tokenHash: tokenHash
                    )
                    var updated = document
                    updated.grants[admittedContext.profile.id] = grant
                    updated.appAttestKeyRejected = false
                    do { try credentials.save(updated) }
                    catch { throw PushRegistrationError.persistence }
                    document = updated
                    diagnostic = .transferringGrant
                    readiness = await transfer(grant, client: admittedContext.client) ? .ready : .pending
                    diagnostic = readiness == .ready ? .complete : .stoppedUnavailable
                    return
                } catch PushRegistrationError.rejected(401) {
                    guard mode == .assertion, !recoveredInvalidKey else {
                        if mode == .attestation { try markCurrentKeyRejected() }
                        throw PushRegistrationError.rejected(401)
                    }
                    try rotateInvalidKey()
                    recoveredInvalidKey = true
                    mode = .attestation
                    continue
                } catch PushRegistrationError.persistence {
                    // A local commit failure says nothing about key validity.
                    throw PushRegistrationError.persistence
                } catch {
                    // An attestation request may have crossed the service boundary.
                    // Its persisted key can only continue with a new assertion.
                    if mode == .attestation, Self.isRetryable(error) {
                        mode = .assertion
                    } else if mode == .attestation {
                        try markCurrentKeyRejected()
                    }
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isRetryable(error) else { throw error }
                guard retryIndex < Self.retryBackoffs.count else {
                    throw PushRegistrationError.retryExhausted
                }
                diagnostic = .retryBackoff
                let delay = Self.retryBackoffs[retryIndex]
                retryIndex &+= 1
                try await clock.sleep(delay)
                try validateRegistration(generation: generation, profileID: admittedContext.profile.id, token: token)
            }
        }
    }

    private func validateRegistration(generation: Int, profileID: String, token: String) throws {
        try Task.checkCancellation()
        guard registrationGeneration == generation,
              context?.profile.id == profileID,
              document.apnsToken == token else { throw CancellationError() }
    }

    private func rotateInvalidKey() throws {
        try persistAppAttestKeyID(nil, rejected: false)
    }

    private func markCurrentKeyRejected() throws {
        try persistAppAttestKeyID(document.appAttestKeyID, rejected: true)
    }

    private func persistAppAttestKeyID(_ keyID: String?, rejected: Bool) throws {
        var updated = document
        updated.appAttestKeyID = keyID
        updated.appAttestKeyRejected = rejected
        do { try credentials.save(updated) }
        catch { throw PushRegistrationError.persistence }
        document = updated
    }

    private static func isInvalidAppAttestKey(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == DCError.errorDomain
            && value.code == DCError.Code.invalidKey.rawValue
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case PushRegistrationError.rejected(let status) = error {
            return (500...599).contains(status)
        }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == URLError.timedOut.rawValue
    }

    private static func diagnostic(for error: PushRegistrationError) -> PushRegistrationDiagnostic {
        switch error {
        case .rejected: .stoppedRejected
        case .invalidCredentialState, .invalidResponse, .invalidConfiguration: .stoppedInvalidResponse
        case .persistence: .stoppedPersistence
        case .invalidAppAttestKey: .stoppedInvalidKey
        case .retryExhausted: .stoppedExhausted
        case .unavailable: .stoppedUnavailable
        }
    }

    private func transfer(_ grant: PushGrant, client: GatewayClient) async -> Bool {
        do {
            let status: PushRegistrationStatus = try await client.request(
                "push.registration.upsert",
                PushRegistrationTransfer(
                    commandId: uuid().uuidString,
                    installationId: grant.installationID,
                    grantId: grant.grantID,
                    secret: grant.grantSecret,
                    previewsEnabled: false
                ),
                timeout: .seconds(8)
            )
            return status.available && status.registered && status.deviceRegistered && status.enabledDeviceCount > 0
        } catch {
            return false
        }
    }

    private func removeRegistration(for profile: GatewayProfile, client: GatewayClient) async {
        guard document.grants[profile.id] != nil else { return }
        do {
            let result: PushRegistrationRemovalResult = try await client.request(
                "push.registration.remove",
                PushRegistrationRemoval(commandId: uuid().uuidString),
                timeout: .seconds(8)
            )
            _ = result.removed // false is an idempotent already-absent acknowledgement.
            document.grants.removeValue(forKey: profile.id)
            try credentials.save(document)
            readiness = .denied
        } catch {
            // Permission denial remains authoritative locally. The next connected
            // reconciliation retries removal without blocking chat or pairing.
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isOpaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
