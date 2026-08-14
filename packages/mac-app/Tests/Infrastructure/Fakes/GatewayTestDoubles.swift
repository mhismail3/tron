import Foundation
import Testing
@testable import TronMac

enum TestFailure: Error {
    case requested
}

enum TestTempDir {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-mac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    static func cleanup(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove test directory: \(error.localizedDescription)")
        }
    }
}

enum TestRepository {
    static let macAppRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

final class MockGatewayHealthChecker: GatewayHealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [GatewayHealthResult]
    private var index = 0
    private var _callCount = 0
    var delayNanoseconds: UInt64 = 0

    init(_ results: [GatewayHealthResult] = [.success(GatewayHealthInfo(version: "test"))]) {
        self.results = results
    }

    var callCount: Int { lock.withLock { _callCount } }

    func replaceResults(_ values: [GatewayHealthResult]) {
        lock.withLock {
            results = values
            index = 0
        }
    }

    func check(bearerToken: String?) async -> GatewayHealthResult {
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return .unreachable
            }
        }
        return lock.withLock {
            _callCount += 1
            guard !results.isEmpty else { return .unreachable }
            let value = results[min(index, results.count - 1)]
            index += 1
            return value
        }
    }
}

final class MockGatewayRequirements: GatewaySystemRequirementsChecking, @unchecked Sendable {
    private let lock = NSLock()
    var delayNanoseconds: UInt64 = 0
    private var _tailscale: TailscaleStatus
    private var _permissions: [Permission: PermissionStatus]

    init(
        tailscale: TailscaleStatus = .signedIn(ipv4: "100.64.0.1"),
        permissions: [Permission: PermissionStatus] = [.fullDiskAccess: .granted]
    ) {
        _tailscale = tailscale
        _permissions = permissions
    }

    var tailscale: TailscaleStatus {
        get { lock.withLock { _tailscale } }
        set { lock.withLock { _tailscale = newValue } }
    }

    var permissions: [Permission: PermissionStatus] {
        get { lock.withLock { _permissions } }
        set { lock.withLock { _permissions = newValue } }
    }

    func tailscaleStatus() async -> TailscaleStatus {
        await delay()
        return tailscale
    }

    func permissionStatuses() async -> [Permission: PermissionStatus] {
        await delay()
        return permissions
    }

    private func delay() async {
        guard delayNanoseconds > 0 else { return }
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            return
        }
    }
}

struct MockGatewayCredentials: GatewayCredentialReading {
    var token: String? = "test-token"
    var code: String? = "test-code"

    func bearerToken() -> String? { token }
    func enrollmentCode() -> String? { code }
}

final class MockGatewayStateStore: GatewayStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var _storedState: GatewayStoredState
    private var _writes: [GatewayAppState] = []
    private var _removeCount = 0
    var failWrites = false
    var failRemovals = false

    init(_ storedState: GatewayStoredState = .missing) {
        _storedState = storedState
    }

    var storedState: GatewayStoredState {
        get { lock.withLock { _storedState } }
        set { lock.withLock { _storedState = newValue } }
    }
    var writes: [GatewayAppState] { lock.withLock { _writes } }
    var removeCount: Int { lock.withLock { _removeCount } }

    func read() -> GatewayStoredState { storedState }

    func write(_ state: GatewayAppState) throws {
        try lock.withLock {
            if failWrites { throw TestFailure.requested }
            _writes.append(state)
            _storedState = .valid(state)
        }
    }

    func remove() throws {
        try lock.withLock {
            if failRemovals { throw TestFailure.requested }
            _removeCount += 1
            _storedState = .missing
        }
    }
}

enum GatewayTestDependencies {
    static let version = GatewayAppVersion(canonicalVersion: "1.2.3", buildNumber: "123")

    static func make(
        root: URL,
        service: MockGatewayServiceManager = MockGatewayServiceManager(),
        health: MockGatewayHealthChecker = MockGatewayHealthChecker(),
        state: MockGatewayStateStore = MockGatewayStateStore(),
        requirements: MockGatewayRequirements = MockGatewayRequirements(),
        credentials: MockGatewayCredentials = MockGatewayCredentials(),
        healthPolicy: GatewayHealthPolicy = GatewayHealthPolicy(attempts: 2, delayNanoseconds: 0)
    ) -> GatewayDependencies {
        GatewayDependencies(
            configuration: GatewayPaths.configuration(
                mode: .development,
                applicationBundle: root.appendingPathComponent("Tron.app", isDirectory: true),
                homeDirectory: root,
                bundleIdentifier: GatewayRuntimeMode.developmentBundleIdentifier
            ),
            serviceManager: service,
            healthChecker: health,
            stateStore: state,
            requirements: requirements,
            credentials: credentials,
            currentVersion: version,
            healthPolicy: healthPolicy
        )
    }
}
