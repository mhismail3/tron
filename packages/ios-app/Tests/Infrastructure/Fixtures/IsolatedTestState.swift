import Foundation
import XCTest

@testable import TronMobile

enum IsolatedTestStateError: LocalizedError {
    case invalidArtifactRoot(String)

    var errorDescription: String? {
        switch self {
        case .invalidArtifactRoot(let value):
            return "TRON_VISUAL_ARTIFACT_DIR must be a non-empty absolute path, got '\(value)'"
        }
    }
}

enum HostedTestKeychainLifecycleEvent: String, Sendable {
    case registered
    case cleaned
}

struct HostedTestKeychainLifecycleRecord: Equatable, Sendable {
    static let prefix = "TRON_TEST_KEYCHAIN_LIFECYCLE_V1 "

    let event: HostedTestKeychainLifecycleEvent
    let namespace: String
    let service: String
    let account: String

    var line: String {
        let payload: [String: String] = [
            "account": account,
            "event": event.rawValue,
            "namespace": namespace,
            "service": service,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    static func parse(line: String) -> Self? {
        guard line.hasPrefix(prefix),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              payload.count == 4,
              let eventValue = payload["event"] as? String,
              let event = HostedTestKeychainLifecycleEvent(rawValue: eventValue),
              let namespace = payload["namespace"] as? String,
              let service = payload["service"] as? String,
              let account = payload["account"] as? String,
              isSupportedIdentity(namespace: namespace, service: service, account: account)
        else { return nil }
        return Self(event: event, namespace: namespace, service: service, account: account)
    }

    static func isSupportedIdentity(namespace: String, service: String, account: String) -> Bool {
        UUID(uuidString: namespace) != nil
            && service == "com.tron.tests.bearer.\(namespace)"
            && service != PairedServerTokenStore.keychainServicePrefix
            && !account.isEmpty
            && !account.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

final class HostedTestKeychainLifecycleEmitter: @unchecked Sendable {
    static let standard = HostedTestKeychainLifecycleEmitter { line in
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    private let lock = NSLock()
    private let write: (String) -> Void

    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    func emit(_ record: HostedTestKeychainLifecycleRecord) {
        precondition(
            HostedTestKeychainLifecycleRecord.isSupportedIdentity(
                namespace: record.namespace,
                service: record.service,
                account: record.account
            ),
            "Hosted test Keychain identity does not match the owned grammar"
        )
        lock.lock()
        write(record.line)
        lock.unlock()
    }
}

/// Lock-backed bearer-token owner used only by hosted tests. Token material
/// never leaves this object through lifecycle evidence.
final class HostedTestPairedServerTokenBackend: @unchecked Sendable {
    let id = UUID()
    let namespace: String
    let service: String

    private let condition = NSCondition()
    private let emitter: HostedTestKeychainLifecycleEmitter
    private var tokens: [String: String] = [:]
    private var registered: Set<String> = []
    private var registrationPending: Set<String> = []
    private var cleaned: Set<String> = []
    private var isTerminal = false

    init(
        namespace: String = UUID().uuidString,
        emitter: HostedTestKeychainLifecycleEmitter = .standard
    ) {
        precondition(UUID(uuidString: namespace) != nil)
        self.namespace = namespace
        service = "com.tron.tests.bearer.\(namespace)"
        self.emitter = emitter
    }

    func makeStore() -> PairedServerTokenStore {
        PairedServerTokenStore(
            backend: .init(
                setToken: { [self] token, account in
                    prepareIdentity(account)
                    condition.lock()
                    precondition(!isTerminal, "Hosted token backend used after cleanup")
                    tokens[account] = token
                    condition.unlock()
                },
                token: { [self] account in
                    prepareIdentity(account)
                    condition.lock()
                    precondition(!isTerminal, "Hosted token backend used after cleanup")
                    let token = tokens[account]
                    condition.unlock()
                    return token
                },
                remove: { [self] account in
                    prepareIdentity(account)
                    condition.lock()
                    precondition(!isTerminal, "Hosted token backend used after cleanup")
                    tokens.removeValue(forKey: account)
                    condition.unlock()
                }
            )
        )
    }

    private func prepareIdentity(_ account: String) {
        condition.lock()
        precondition(!isTerminal, "Hosted token backend used after cleanup")
        while registrationPending.contains(account) {
            condition.wait()
        }
        guard !registered.contains(account) else {
            condition.unlock()
            return
        }
        registrationPending.insert(account)
        let record = HostedTestKeychainLifecycleRecord(
            event: .registered,
            namespace: namespace,
            service: service,
            account: account
        )
        condition.unlock()

        emitter.emit(record)

        condition.lock()
        registrationPending.remove(account)
        registered.insert(account)
        condition.broadcast()
        condition.unlock()
    }

    func cleanup() {
        condition.lock()
        while !registrationPending.isEmpty {
            condition.wait()
        }
        guard !isTerminal else {
            condition.unlock()
            return
        }
        isTerminal = true
        let accounts = registered.subtracting(cleaned).sorted()
        for account in accounts {
            tokens.removeValue(forKey: account)
            cleaned.insert(account)
        }
        precondition(tokens.isEmpty, "Hosted token backend cleanup left token identities")
        condition.unlock()

        for account in accounts {
            emitter.emit(
                HostedTestKeychainLifecycleRecord(
                    event: .cleaned,
                    namespace: namespace,
                    service: service,
                    account: account
                )
            )
        }
    }

    var isEmpty: Bool {
        condition.lock()
        let result = tokens.isEmpty
        condition.unlock()
        return result
    }
}

private final class HostedTestTokenBackendRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [UUID: HostedTestPairedServerTokenBackend] = [:]

    func register(_ backend: HostedTestPairedServerTokenBackend) {
        lock.lock()
        backends[backend.id] = backend
        lock.unlock()
    }

    func takeAll() -> [HostedTestPairedServerTokenBackend] {
        lock.lock()
        let result = Array(backends.values)
        backends.removeAll()
        lock.unlock()
        return result
    }

    var count: Int {
        lock.lock()
        let result = backends.count
        lock.unlock()
        return result
    }
}

final class HostedEngineAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func handle(_ request: URLRequest) -> EngineSessionAttemptDirective {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
        return .handledFailure
    }

    var requests: [URLRequest] {
        lock.lock()
        let result = recordedRequests
        lock.unlock()
        return result
    }
}

/// The only general-purpose owner for test defaults, local databases,
/// Documents roots, and visual artifacts. Every instance is registered before
/// its state is exposed and cleanup drains managers before closing databases.
@MainActor
final class IsolatedTestState {
    let id = UUID()
    let suiteName: String
    let defaults: UserDefaults
    let rootURL: URL
    let documentsURL: URL

    private var databases: [EventDatabase] = []
    private var eventStoreManagers: [EventStoreManager] = []
    private(set) var attemptRecorders: [HostedEngineAttemptRecorder] = []
    private(set) var pairingProbes: [StubPairingProbe] = []
    private let tokenBackendRegistry = HostedTestTokenBackendRegistry()
    private let keychainLifecycleEmitter: HostedTestKeychainLifecycleEmitter
    private let suiteLifecycle: HostedTestSuiteLifecycle
    private let cleanupRegistry: AppRuntimeCleanupRegistry
    private var cleanupTask: Task<Void, Never>?
    private var isTerminal = false
    private var processCleanupRegistration: UUID?

    private static var registered: [UUID: IsolatedTestState] = [:]

    init(
        label: String = "state",
        lifecycleEmitter: HostedTestSuiteLifecycleEmitter = .standard,
        keychainLifecycleEmitter: HostedTestKeychainLifecycleEmitter = .standard,
        cleanupRegistry: AppRuntimeCleanupRegistry = .shared
    ) {
        let normalizedLabel = label
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let safeLabel = normalizedLabel.isEmpty ? "state" : normalizedLabel
        suiteName = "com.tron.tests.\(safeLabel).\(id.uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated defaults suite \(suiteName)")
        }
        self.defaults = defaults

        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-tests-\(safeLabel)-\(id.uuidString)", isDirectory: true)
        documentsURL = rootURL.appendingPathComponent("Documents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: documentsURL,
                withIntermediateDirectories: true
            )
        } catch {
            preconditionFailure("Unable to create isolated test root: \(error)")
        }
        suiteLifecycle = HostedTestSuiteLifecycle(
            defaults: defaults,
            suiteName: suiteName,
            emitter: lifecycleEmitter
        )
        self.keychainLifecycleEmitter = keychainLifecycleEmitter
        self.cleanupRegistry = cleanupRegistry
        Self.registered[id] = self
        let cleanupRootURL = rootURL
        let tokenBackendRegistry = tokenBackendRegistry
        processCleanupRegistration = cleanupRegistry.register { [suiteLifecycle] in
            tokenBackendRegistry.takeAll().forEach { $0.cleanup() }
            try? FileManager.default.removeItem(at: cleanupRootURL)
            suiteLifecycle.cleanup()
        }
    }

    func registerTeardown(with testCase: XCTestCase) {
        testCase.addTeardownBlock { [self] in
            await cleanup()
        }
    }

    func makeDatabase(fileName: String = "events.db") -> EventDatabase {
        precondition(!isTerminal, "Cannot create a database after fixture cleanup begins")
        let databaseURL = rootURL
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent(fileName)
        let database = EventDatabase(databasePath: databaseURL.path)
        databases.append(database)
        return database
    }

    func makeContainer() -> DependencyContainer {
        precondition(!isTerminal, "Cannot create a container after fixture cleanup begins")
        let database = makeDatabase(fileName: "container-\(UUID().uuidString).db")
        let tokenBackend = HostedTestPairedServerTokenBackend(emitter: keychainLifecycleEmitter)
        tokenBackendRegistry.register(tokenBackend)
        let attemptRecorder = HostedEngineAttemptRecorder()
        let pairingProbe = StubPairingProbe()
        let container = DependencyContainer(
            storage: DependencyContainerStorage(
                defaults: defaults,
                documentsURL: documentsURL,
                eventDatabase: database
            ),
            runtimeIO: DependencyContainerRuntimeIO(
                sessionAttemptDirective: { [attemptRecorder] request in
                    attemptRecorder.handle(request)
                },
                pairedServerTokenStore: tokenBackend.makeStore(),
                makePairingProbe: { pairingProbe }
            )
        )
        eventStoreManagers.append(container.eventStoreManager)
        attemptRecorders.append(attemptRecorder)
        pairingProbes.append(pairingProbe)
        return container
    }

    func artifactURL(
        named fileName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let directory: URL
        if let configured = environment["TRON_VISUAL_ARTIFACT_DIR"] {
            guard !configured.isEmpty, configured.hasPrefix("/") else {
                throw IsolatedTestStateError.invalidArtifactRoot(configured)
            }
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            directory = rootURL.appendingPathComponent("Artifacts", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    func cleanup() async {
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        isTerminal = true

        let ownedManagers = eventStoreManagers
        eventStoreManagers.removeAll()
        let ownedTokenBackends = tokenBackendRegistry.takeAll()
        let ownedDatabases = databases
        databases.removeAll()
        attemptRecorders.removeAll()
        pairingProbes.removeAll()
        let cleanupRegistration = processCleanupRegistration
        processCleanupRegistration = nil
        let stateID = id
        let rootURL = rootURL
        let suiteLifecycle = suiteLifecycle
        let cleanupRegistry = cleanupRegistry

        let drain = Task { @MainActor in
            for manager in ownedManagers {
                await manager.shutdown()
            }
            ownedTokenBackends.forEach { $0.cleanup() }
            for database in ownedDatabases {
                await database.close()
            }
            try? FileManager.default.removeItem(at: rootURL)
            suiteLifecycle.cleanup()
            if let cleanupRegistration {
                cleanupRegistry.deregister(cleanupRegistration)
            }
            Self.registered.removeValue(forKey: stateID)
        }
        cleanupTask = drain
        await drain.value
    }

    /// Synchronous cleanup for defaults-only scopes. Database-owning fixtures
    /// must use `cleanup()` so close ordering is awaited.
    func cleanupDefaultsSynchronously() {
        precondition(databases.isEmpty, "Synchronous defaults scopes cannot own databases")
        precondition(eventStoreManagers.isEmpty, "Synchronous defaults scopes cannot own managers")
        precondition(tokenBackendRegistry.count == 0, "Synchronous defaults scopes cannot own token backends")
        guard cleanupTask == nil, !isTerminal else { return }
        isTerminal = true
        try? FileManager.default.removeItem(at: rootURL)
        suiteLifecycle.cleanup()
        if let processCleanupRegistration {
            cleanupRegistry.deregister(processCleanupRegistration)
        }
        processCleanupRegistration = nil
        Self.registered.removeValue(forKey: id)
    }

    static func withDefaults<T>(
        label: String = "defaults",
        lifecycleEmitter: HostedTestSuiteLifecycleEmitter = .standard,
        cleanupRegistry: AppRuntimeCleanupRegistry = .shared,
        _ body: (UserDefaults) throws -> T
    ) rethrows -> T {
        let state = IsolatedTestState(
            label: label,
            lifecycleEmitter: lifecycleEmitter,
            cleanupRegistry: cleanupRegistry
        )
        defer { state.cleanupDefaultsSynchronously() }
        return try body(state.defaults)
    }

    static func withState<T>(
        label: String = "state",
        lifecycleEmitter: HostedTestSuiteLifecycleEmitter = .standard,
        cleanupRegistry: AppRuntimeCleanupRegistry = .shared,
        _ body: (IsolatedTestState) async throws -> T
    ) async rethrows -> T {
        let state = IsolatedTestState(
            label: label,
            lifecycleEmitter: lifecycleEmitter,
            cleanupRegistry: cleanupRegistry
        )
        do {
            let value = try await body(state)
            await state.cleanup()
            return value
        } catch {
            await state.cleanup()
            throw error
        }
    }

    /// Named-suite construction and inspection stay centralized here so tests
    /// cannot create an unregistered ad-hoc suite owner.
    static func namedDefaults(for suiteName: String) -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func persistentDomain(named suiteName: String) -> [String: Any]? {
        UserDefaults.standard.persistentDomain(forName: suiteName)
    }

    static var registeredStateCount: Int {
        registered.count
    }

    static func cleanupAllRegistered() async {
        let states = Array(registered.values)
        for state in states {
            await state.cleanup()
        }
    }
}
