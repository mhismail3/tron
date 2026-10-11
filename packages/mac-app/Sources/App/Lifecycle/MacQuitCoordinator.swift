import Foundation

/// Owns one user Quit across Gateway drain, exact process disappearance and
/// native-host retirement. Uncertain stages fail closed; the caller leaves UI open.
/// A Quit retried after the Gateway has stopped (for example, native-host
/// retirement failed) resumes at retirement only while the Login Item is enabled
/// and launchd reports no running Gateway process.
@MainActor
final class MacQuitCoordinator {
    enum Failure: Error, LocalizedError, Equatable {
        case unmanaged
        case ownership
        case runtimeUnavailable
        case runtimeReplaced
        case observation
        case exitStalled

        var errorDescription: String? {
            switch self {
            case .unmanaged: "This wrapper does not own the installed Gateway."
            case .ownership: "Could not verify the Gateway owned by this app. No shutdown was requested."
            case .runtimeUnavailable: "The exact Gateway runtime could not be observed. Tron remains open."
            case .runtimeReplaced: "The Gateway changed while Quit was waiting. Tron remains open."
            case .observation: "Could not confirm that the Gateway stopped. Tron remains open."
            case .exitStalled: "The Gateway completed shutdown but its process did not exit. Tron remains open; retry Quit after checking the Gateway."
            }
        }
    }

    private struct RuntimeIdentity: Equatable {
        let pid: Int
        let command: String
        let start: String
    }

    private let readRuntime: @Sendable () async throws -> LaunchAgentRuntimeInfo?
    private let processStartIdentity: @Sendable (Int) async -> String?
    private let runtimeOwnershipHealthy: @Sendable () async -> Bool
    private let serviceEnabled: @Sendable () -> Bool
    private let shutdownCompleted: @Sendable (Int, Date) async -> Bool
    private let exitStallGrace: Duration
    private let stopGateway: @Sendable (String) async throws -> GatewayStopClient.Response
    private let retireNativeHost: @Sendable () async throws -> Void
    private let wait: @Sendable () async throws -> Void
    private var attempt: (identity: RuntimeIdentity, commandID: String)?
    private var pending: Task<Void, Error>?

    init(
        readRuntime: @escaping @Sendable () async throws -> LaunchAgentRuntimeInfo?,
        processStartIdentity: @escaping @Sendable (Int) async -> String?,
        runtimeOwnershipHealthy: @escaping @Sendable () async -> Bool,
        serviceEnabled: @escaping @Sendable () -> Bool,
        shutdownCompleted: @escaping @Sendable (Int, Date) async -> Bool = { _, _ in false },
        exitStallGrace: Duration = .seconds(5),
        stopGateway: @escaping @Sendable (String) async throws -> GatewayStopClient.Response,
        retireNativeHost: @escaping @Sendable () async throws -> Void,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) {
        self.readRuntime = readRuntime
        self.processStartIdentity = processStartIdentity
        self.runtimeOwnershipHealthy = runtimeOwnershipHealthy
        self.serviceEnabled = serviceEnabled
        self.shutdownCompleted = shutdownCompleted
        self.exitStallGrace = exitStallGrace
        self.stopGateway = stopGateway
        self.retireNativeHost = retireNativeHost
        self.wait = wait
    }

    func quit() async throws {
        if let pending { return try await pending.value }
        let task = Task { @MainActor [self] in try await perform() }
        pending = task
        do { try await task.value }
        catch { pending = nil; throw error }
    }

    private func perform() async throws {
        if await runtimeOwnershipHealthy() {
            try await stopOwnedRuntime()
        } else {
            // Unowned means either stopped (resume) or running but foreign. Only an
            // enabled service with no running process resumes; a foreign runtime or
            // a disabled service is refused without a stop request.
            guard serviceEnabled(), try await readRuntime()?.pid == nil else { throw Failure.unmanaged }
        }
        try await retireNativeHost()
    }

    private func stopOwnedRuntime() async throws {
        guard let before = try await readRuntime(), let pid = before.pid,
              let command = before.processCommand,
              let start = await processStartIdentity(pid), !start.isEmpty else {
            throw Failure.runtimeUnavailable
        }
        let identity = RuntimeIdentity(pid: pid, command: command, start: start)
        guard let confirmed = try await readRuntime(), confirmed.pid == pid,
              confirmed.processCommand == command,
              await processStartIdentity(pid) == start,
              await runtimeOwnershipHealthy() else {
            throw Failure.runtimeReplaced
        }
        if attempt?.identity != identity {
            attempt = (identity, "mac-quit-\(UUID().uuidString.lowercased())")
        }
        // A retry after uncertainty reuses this exact runtime's receipt. There is
        // no automatic replay and a different runtime always gets a new attempt.
        let stopRequestedAt = Date()
        _ = try await stopGateway(attempt!.commandID)
        var shutdownObservedAt: ContinuousClock.Instant?
        let clock = ContinuousClock()
        while true {
            let current = try await readRuntime()
            guard let current else { break }
            guard let currentPID = current.pid else { break }
            guard currentPID == identity.pid,
                  current.processCommand == identity.command,
                  await processStartIdentity(currentPID) == identity.start else {
                throw Failure.runtimeReplaced
            }
            if await shutdownCompleted(identity.pid, stopRequestedAt) {
                let observedAt = shutdownObservedAt ?? clock.now
                shutdownObservedAt = observedAt
                if observedAt.duration(to: clock.now) >= exitStallGrace {
                    TronLog.shared.record(
                        .error, event: "app.quit.gateway-exit-stalled", source: "lifecycle",
                        message: "Gateway completed intentional shutdown but its exact process remained alive beyond the exit grace",
                        commandId: attempt?.commandID, why: "pid=\(identity.pid)", outcome: "blocked"
                    )
                    throw Failure.exitStalled
                }
            }
            try await wait()
        }
    }

    static func hasCompletedShutdown(pid: Int, since: Date, logURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return false }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 128_000 ? size - 128_000 : 0)
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { return false }
            let formatter = ISO8601DateFormatter()
            return text.split(separator: "\n").reversed().contains { line in
                guard let bytes = line.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                guard let timestamp = value["timestamp"] as? String,
                      let recordedAt = formatter.date(from: timestamp), recordedAt >= since else { return false }
                return value["event"] as? String == "gateway.stopped"
                    && (value["pid"] as? NSNumber)?.intValue == pid
                    && value["code"] as? String == "0"
            }
        }.value
    }

    static func shouldCoordinate(mode: MacStartupMode, ownsLock: Bool, canManage: Bool) -> Bool {
        ownsLock && canManage && (mode == .onboarded || mode == .wizard)
    }
}
