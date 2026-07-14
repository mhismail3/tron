import Foundation
import SwiftUI

/// Selects the process graph before any production dependency is evaluated.
enum AppRuntimeMode: Equatable, Sendable {
    case application
    case hostedUnitTests

    private static let hostedXCTestMarkers = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto",
    ]

    static func resolve(
        environment: [String: String],
        arguments: [String]
    ) -> Self {
        _ = arguments
        // Apple injection markers are authoritative by presence. The scheme
        // value is deliberately only audit evidence: ambient state cannot
        // turn a normal, preview, or separate UI-test app into an inert host.
        if hostedXCTestMarkers.contains(where: { environment.keys.contains($0) }) {
            return .hostedUnitTests
        }
        return .application
    }

    var runsApplicationLifecycle: Bool {
        self == .application
    }
}

/// Stores a production root without evaluating its factory in hosted XCTest.
struct AppBootstrap<ProductionRoot> {
    let mode: AppRuntimeMode
    let productionRoot: ProductionRoot?

    init(mode: AppRuntimeMode, makeProductionRoot: () -> ProductionRoot) {
        self.mode = mode
        productionRoot = mode.runsApplicationLifecycle ? makeProductionRoot() : nil
    }
}

/// Dependency-free root mounted by the hosted test executable.
struct HostedUnitTestRoot: View {
    var body: some View {
        Color.clear
            .accessibilityHidden(true)
    }
}

/// Synchronous cleanup registry for process-scoped runtime state. Per-test
/// databases use the ordered async fixture registry in `IsolatedTestState`.
final class AppRuntimeCleanupRegistry: @unchecked Sendable {
    static let shared = AppRuntimeCleanupRegistry(registerProcessExit: true)

    private let lock = NSLock()
    private var actions: [UUID: () -> Void] = [:]

    init(registerProcessExit: Bool = false) {
        if registerProcessExit {
            atexit(tronCleanupAppRuntimeStorageAtExit)
        }
    }

    @discardableResult
    func register(_ action: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        actions[id] = action
        lock.unlock()
        return id
    }

    func deregister(_ id: UUID) {
        lock.lock()
        actions.removeValue(forKey: id)
        lock.unlock()
    }

    func cleanupAll() {
        lock.lock()
        let pending = actions
        actions.removeAll()
        lock.unlock()
        pending.values.forEach { $0() }
    }
}

enum HostedTestSuiteLifecycleEvent: String, Sendable {
    case registered
    case cleaned
}

struct HostedTestSuiteLifecycleRecord: Equatable, Sendable {
    static let prefix = "TRON_TEST_SUITE_LIFECYCLE_V1 "

    let event: HostedTestSuiteLifecycleEvent
    let suite: String

    var line: String {
        "\(Self.prefix){\"event\":\"\(event.rawValue)\",\"suite\":\"\(suite)\"}"
    }

    static func parse(line: String) -> Self? {
        guard line.hasPrefix(prefix),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              payload.count == 2,
              let eventValue = payload["event"] as? String,
              let event = HostedTestSuiteLifecycleEvent(rawValue: eventValue),
              let suite = payload["suite"] as? String,
              isSupportedSuiteName(suite)
        else { return nil }
        return Self(event: event, suite: suite)
    }

    static func isSupportedSuiteName(_ suiteName: String) -> Bool {
        let pattern = #"^com\.tron\.(hosted-unit-tests|tests)\.[A-Za-z0-9-]+\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (suiteName as NSString).length)
        return expression.firstMatch(in: suiteName, range: range)?.range == range
    }
}

final class HostedTestSuiteLifecycleEmitter: @unchecked Sendable {
    static let standard = HostedTestSuiteLifecycleEmitter { line in
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    private let lock = NSLock()
    private let write: (String) -> Void

    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    func emit(_ event: HostedTestSuiteLifecycleEvent, suite: String) {
        let record = HostedTestSuiteLifecycleRecord(event: event, suite: suite)
        precondition(
            HostedTestSuiteLifecycleRecord.isSupportedSuiteName(suite),
            "Hosted test suite identity does not match an owned grammar"
        )
        lock.lock()
        write(record.line)
        lock.unlock()
    }
}

/// Owns the semantic lifetime of one hosted test defaults suite. Registration
/// precedes outward exposure and cleanup is emitted only after the domain is
/// empty. The lock makes normal, repeated, and process-fallback cleanup one
/// idempotent transition.
final class HostedTestSuiteLifecycle: @unchecked Sendable {
    private let defaults: UserDefaults
    private let suiteName: String
    private let emitter: HostedTestSuiteLifecycleEmitter
    private let lock = NSLock()
    private var cleaned = false

    init(
        defaults: UserDefaults,
        suiteName: String,
        emitter: HostedTestSuiteLifecycleEmitter = .standard
    ) {
        self.defaults = defaults
        self.suiteName = suiteName
        self.emitter = emitter
        emitter.emit(.registered, suite: suiteName)
    }

    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned else { return }

        AppRuntimeStorage.removeTestSuite(defaults, named: suiteName)
        precondition(
            AppRuntimeStorage.isTestSuiteSemanticallyEmpty(defaults, named: suiteName),
            "Hosted test suite cleanup left persistent values"
        )
        emitter.emit(.cleaned, suite: suiteName)
        cleaned = true
    }
}

private final class AppRuntimeCleanupHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func cleanup() {
        lock.lock()
        let pending = action
        action = nil
        lock.unlock()
        pending?()
    }
}

/// Defaults selected at the process boundary. Real and separate UI-test apps
/// retain `.standard`; a hosted unit-test process gets a collision-proof suite
/// with explicit identity and idempotent cleanup.
struct AppRuntimeStorage {
    let defaults: UserDefaults
    let suiteName: String?

    private let cleanupHandle: AppRuntimeCleanupHandle?
    private let cleanupRegistry: AppRuntimeCleanupRegistry?
    private let cleanupRegistration: UUID?

    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var currentValue: AppRuntimeStorage?

    static func removeTestSuite(
        _ defaults: UserDefaults,
        named suiteName: String
    ) {
        precondition(
            suiteName.hasPrefix("com.tron.hosted-unit-tests.")
                || suiteName.hasPrefix("com.tron.tests."),
            "Named-suite cleanup is restricted to Tron-hosted test domains"
        )
        defaults.removePersistentDomain(forName: suiteName)
    }

    static func isTestSuiteSemanticallyEmpty(
        _ defaults: UserDefaults,
        named suiteName: String
    ) -> Bool {
        defaults.persistentDomain(forName: suiteName)?.isEmpty != false
    }

    static var current: Self {
        currentLock.lock()
        defer { currentLock.unlock() }
        if let currentValue {
            return currentValue
        }

        let mode = AppRuntimeMode.resolve(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
        let storage = make(
            mode: mode,
            processIdentity: String(ProcessInfo.processInfo.processIdentifier)
        )
        currentValue = storage
        return storage
    }

    static func make(
        mode: AppRuntimeMode,
        processIdentity: String,
        applicationDefaults: UserDefaults = .standard,
        namedSuiteFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
        lifecycleEmitter: HostedTestSuiteLifecycleEmitter = .standard,
        cleanupRegistry: AppRuntimeCleanupRegistry = .shared
    ) -> Self {
        guard mode == .hostedUnitTests else {
            return Self(
                defaults: applicationDefaults,
                suiteName: nil,
                cleanupHandle: nil,
                cleanupRegistry: nil,
                cleanupRegistration: nil
            )
        }

        let normalizedIdentity = processIdentity
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let safeIdentity = normalizedIdentity.isEmpty ? "process" : normalizedIdentity
        let suiteName = "com.tron.hosted-unit-tests.\(safeIdentity).\(UUID().uuidString)"
        applicationDefaults.removePersistentDomain(forName: suiteName)
        guard let defaults = namedSuiteFactory(suiteName) else {
            preconditionFailure("Unable to create hosted unit-test defaults suite \(suiteName)")
        }

        let lifecycle = HostedTestSuiteLifecycle(
            defaults: defaults,
            suiteName: suiteName,
            emitter: lifecycleEmitter
        )
        let handle = AppRuntimeCleanupHandle { lifecycle.cleanup() }
        let cleanupRegistration = cleanupRegistry.register {
            handle.cleanup()
        }
        return Self(
            defaults: defaults,
            suiteName: suiteName,
            cleanupHandle: handle,
            cleanupRegistry: cleanupRegistry,
            cleanupRegistration: cleanupRegistration
        )
    }

    func cleanup() {
        cleanupHandle?.cleanup()
        if let cleanupRegistry, let cleanupRegistration {
            cleanupRegistry.deregister(cleanupRegistration)
        }
    }

    static func cleanupCurrentIfInitialized() {
        currentLock.lock()
        let value = currentValue
        currentValue = nil
        currentLock.unlock()
        value?.cleanup()
        AppRuntimeCleanupRegistry.shared.cleanupAll()
    }
}

private func tronCleanupAppRuntimeStorageAtExit() {
    AppRuntimeStorage.cleanupCurrentIfInitialized()
}
