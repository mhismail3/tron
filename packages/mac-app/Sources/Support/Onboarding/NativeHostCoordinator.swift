import Foundation
import ServiceManagement

enum NativeHostServiceState: Sendable, Equatable {
    case needsRegistration, needsApproval, enabled, unavailable
}

/// Real platform operations are injected at one boundary. Tests never register
/// services, create XPC connections or ask the operating system for consent.
struct NativeHostOperations: Sendable {
    let state: @Sendable () async -> NativeHostServiceState
    let enable: @Sendable () async throws -> Void
    let unregister: @Sendable () async throws -> Void
    let probe: @Sendable () async -> [Permission: PermissionStatus]
    let request: @Sendable (Permission, UUID) async -> PermissionStatus

    static let live: Self = {
        let io = NativeHostPlatform(bundle: TronPaths.nativeHostBundle)
        return Self(state: { await io.state() }, enable: { try await io.enable() },
                    unregister: { try await io.unregister() }, probe: { await io.probe() },
                    request: { await io.request($0, id: $1) })
    }()
}

/// Service activation and TCC consent are explicit separate setup phases. Each
/// accepted command is retained independently of whichever view is waiting.
actor NativeHostCoordinator {
    static let shared = NativeHostCoordinator(operations: .live)
    private let operations: NativeHostOperations
    private var pending: (id: UUID, permission: Permission, task: Task<PermissionStatus, Never>)?
    private enum Command { case enable, refresh, unregister }
    private var lifecycle: (id: UUID, kind: Command, task: Task<NativeHostServiceState, Error>)?
    init(operations: NativeHostOperations) { self.operations = operations }

    func serviceState() async -> NativeHostServiceState { await operations.state() }
    func probe() async -> [Permission: PermissionStatus] {
        guard !Task.isCancelled, await operations.state() == .enabled else { return Self.unavailable }
        return await operations.probe()
    }
    func enable() async -> NativeHostServiceState {
        do { return try await perform(.enable) } catch { return .unavailable }
    }
    func refresh() async -> NativeHostServiceState {
        do { return try await perform(.refresh) } catch { return .unavailable }
    }
    func unregister() async throws { _ = try await perform(.unregister) }

    private func perform(_ kind: Command) async throws -> NativeHostServiceState {
        if let lifecycle {
            guard lifecycle.kind == kind else { throw NativeHostError.busy }
            return try await lifecycle.task.value
        }
        let id = UUID()
        let consent = pending?.task
        let task = Task { [operations] in
            if let consent { _ = await consent.value }
            switch kind {
            case .enable: try await operations.enable()
            case .refresh:
                try await operations.unregister()
                try await operations.enable()
            case .unregister: try await operations.unregister()
            }
            return await operations.state()
        }
        lifecycle = (id, kind, task)
        defer { if lifecycle?.id == id { lifecycle = nil } }
        return try await task.value
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        guard permission != .fullDiskAccess, lifecycle == nil else { return .probeUnavailable }
        if let pending { return pending.permission == permission ? await pending.task.value : .probeUnavailable }
        let id = UUID()
        let task = Task { [operations] in
            guard await operations.state() == .enabled else { return PermissionStatus.probeUnavailable }
            return await operations.request(permission, id)
        }
        pending = (id, permission, task)
        let result = await task.value
        if pending?.id == id { pending = nil }
        return result
    }

    static var unavailable: [Permission: PermissionStatus] {
        [.accessibility: .probeUnavailable, .inputMonitoring: .probeUnavailable, .screenRecording: .probeUnavailable]
    }
}

private struct NativeHostPlatform: Sendable {
    let bundle: URL
    func state() async -> NativeHostServiceState {
        switch SMAppService.agent(plistName: NativeHostTrust.launchAgentPlistName).status {
        case .enabled: .enabled
        case .notRegistered: .needsRegistration
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func enable() async throws {
        guard TronPaths.canManageLaunchAgent,
              await ExistingInstallDetector.validateNativeHost(bundle: bundle,
                  executable: bundle.appendingPathComponent("Contents/MacOS/TronNativeHost")) == nil else {
            throw NativeHostError.bundleUnavailable
        }
        let service = SMAppService.agent(plistName: NativeHostTrust.launchAgentPlistName)
        if service.status == .notRegistered { try service.register() }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return // The UI explicitly shows approval as an unfinished first phase.
        }
        guard service.status == .enabled else { throw NativeHostError.serviceUnavailable }
    }
    func unregister() async throws {
        guard TronPaths.canManageLaunchAgent else { throw NativeHostError.serviceUnavailable }
        let service = SMAppService.agent(plistName: NativeHostTrust.launchAgentPlistName)
        if service.status != .notRegistered { try await service.unregister() }
    }

    func probe() async -> [Permission: PermissionStatus] {
        guard !Task.isCancelled, let connection = try? connect() else { return NativeHostCoordinator.unavailable }
        defer { connection.invalidate() }
        let reply = NativeHostReply<[String: String]>()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            reply.resolve([:]); connection.invalidate()
        }
        defer { timeout.cancel() }
        let values: [String: String] = await withTaskCancellationHandler {
            guard !Task.isCancelled, let service = connection.service(onError: { reply.resolve([:]) }) else { return [:] }
            service.probePermissions { reply.resolve($0) }
            return await reply.value()
        } onCancel: { reply.resolve([:]); connection.invalidate() }
        return [.accessibility, .inputMonitoring, .screenRecording].reduce(into: [:]) { result, permission in
            result[permission] = values[permission.rawValue].flatMap(PermissionStatus.init(rawValue:)) ?? .probeUnavailable
        }
    }

    func request(_ permission: Permission, id: UUID) async -> PermissionStatus {
        guard TronPaths.canManageLaunchAgent,
              let native = NativeHostPermission(rawValue: permission.rawValue),
              let connection = try? connect() else { return .probeUnavailable }
        defer { connection.invalidate() }
        let reply = NativeHostReply<(String, String)>()
        let failure = ("", PermissionStatus.probeUnavailable.rawValue)
        guard let service = connection.service(onError: { reply.resolve(failure) }) else { return .probeUnavailable }
        service.requestPermission(native.rawValue, requestID: id.uuidString) { reply.resolve(($0, $1)) }
        // No UI timeout cancels an accepted native consent command.
        let value = await reply.value()
        guard value.0 == id.uuidString else { return .probeUnavailable }
        return PermissionStatus(rawValue: value.1) ?? .probeUnavailable
    }

    private func connect() throws -> NativeHostConnection {
        let requirement = try NativeHostTrust.pin(NativeHostTrust.hostCodeSigningRequirement, to: bundle)
        let connection = NSXPCConnection(machServiceName: NativeHostTrust.machServiceName)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: NativeHostPermissionService.self)
        connection.activate()
        return NativeHostConnection(connection)
    }
}

/// NSXPC queues messages/invalidation internally. Cancellation closes only this
/// immutable handle's disposable observation, never a consent connection.
private final class NativeHostConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
    func invalidate() { connection.invalidate() }
    func service(onError: @escaping @Sendable () -> Void) -> NativeHostPermissionService? {
        connection.remoteObjectProxyWithErrorHandler { _ in onError() } as? NativeHostPermissionService
    }
    deinit { connection.invalidate() }
}

final class NativeHostReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?
    @discardableResult func resolve(_ value: Value) -> Bool {
        let resolved: (Bool, CheckedContinuation<Value, Never>?) = lock.withLock {
            guard result == nil else { return (false, nil) }
            result = value
            let waiter = continuation; continuation = nil
            return (true, waiter)
        }
        resolved.1?.resume(returning: value)
        return resolved.0
    }
    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let immediate: Value? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

enum NativeHostError: Error { case bundleUnavailable, serviceUnavailable, busy }
