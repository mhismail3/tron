import Foundation

/// Synchronous process fallback for task-owned hosted-test state. Normal test
/// cleanup still uses the fixture's ordered async drain.
final class HostedTestCleanupRegistry: @unchecked Sendable {
    static let shared = HostedTestCleanupRegistry(registerProcessExit: true)

    private let lock = NSLock()
    private var actions: [UUID: () -> Void] = [:]

    init(registerProcessExit: Bool = false) {
        if registerProcessExit {
            atexit(tronCleanupHostedTestStateAtExit)
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
        let pattern = #"^com\.tron\.tests\.[A-Za-z0-9-]+\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
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
            "Hosted test suite identity does not match the owned grammar"
        )
        lock.lock()
        write(record.line)
        lock.unlock()
    }
}

/// Owns the semantic lifetime of one hosted-test defaults suite.
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

        defaults.removePersistentDomain(forName: suiteName)
        precondition(
            defaults.persistentDomain(forName: suiteName)?.isEmpty != false,
            "Hosted test suite cleanup left persistent values"
        )
        emitter.emit(.cleaned, suite: suiteName)
        cleaned = true
    }
}

private func tronCleanupHostedTestStateAtExit() {
    HostedTestCleanupRegistry.shared.cleanupAll()
}
