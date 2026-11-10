import Darwin
import Foundation

@MainActor
final class MacQuitCoordinator {
    enum Failure: Error, LocalizedError, Equatable {
        case unmanaged
        case ownership
        case runtimeUnavailable
        case runtimeReplaced
        case observation
        case exitStalled
        case retirementPolicy

        var errorDescription: String? {
            switch self {
            case .unmanaged: "This wrapper does not own the installed Gateway."
            case .ownership: "Could not verify the Gateway owned by this app. No shutdown was requested."
            case .runtimeUnavailable: "The exact Gateway runtime could not be observed. Tron remains open."
            case .runtimeReplaced: "The Gateway changed while Quit was waiting. Tron remains open."
            case .observation: "Could not confirm that the Gateway stopped. Tron remains open."
            case .exitStalled: "launchd did not confirm retirement of the completed Gateway within its termination window. No app replacement is safe yet. Check mac.jsonl and Login Items, then retry Quit."
            case .retirementPolicy: "The Gateway job has an unknown, infinite, or unsupported launchd exit timeout. No removal was requested. Check its Login Item registration before retrying Quit."
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
    private let shutdownCompleted: @Sendable (Int, String) async -> Bool
    private let readDrain: @Sendable () async throws -> GatewayStopClient.Drain
    private let exitStallGrace: Duration = .seconds(5)
    private let stopGateway: @Sendable (String) async throws -> GatewayStopClient.Response
    private let retireCompletedGateway: @Sendable (Int, String, String) async throws -> Void
    private let retireNativeHost: @Sendable () async throws -> Void
    private let wait: @Sendable () async throws -> Void
    private var attempt: (identity: RuntimeIdentity, commandID: String, response: GatewayStopClient.Response?)?
    private var pending: Task<Void, Error>?

    init(
        readRuntime: @escaping @Sendable () async throws -> LaunchAgentRuntimeInfo?,
        processStartIdentity: @escaping @Sendable (Int) async -> String?,
        runtimeOwnershipHealthy: @escaping @Sendable () async -> Bool,
        serviceEnabled: @escaping @Sendable () -> Bool,
        shutdownCompleted: @escaping @Sendable (Int, String) async -> Bool,
        readDrain: @escaping @Sendable () async throws -> GatewayStopClient.Drain,
        stopGateway: @escaping @Sendable (String) async throws -> GatewayStopClient.Response,
        retireCompletedGateway: @escaping @Sendable (Int, String, String) async throws -> Void,
        retireNativeHost: @escaping @Sendable () async throws -> Void,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }
    ) {
        self.readRuntime = readRuntime
        self.processStartIdentity = processStartIdentity
        self.runtimeOwnershipHealthy = runtimeOwnershipHealthy
        self.serviceEnabled = serviceEnabled
        self.shutdownCompleted = shutdownCompleted
        self.readDrain = readDrain
        self.stopGateway = stopGateway
        self.retireCompletedGateway = retireCompletedGateway
        self.retireNativeHost = retireNativeHost
        self.wait = wait
    }

    func quit(progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        if let pending { return try await pending.value }
        let task = Task { @MainActor [self] in try await perform(progress: progress) }
        pending = task
        do { try await task.value }
        catch { pending = nil; throw error }
    }

    private func perform(progress: @escaping @Sendable (String) async -> Void) async throws {
        await progress("Stopping Gateway; accepted work drains before shutdown")
        if await runtimeOwnershipHealthy() {
            do { try await stopOwnedRuntime(progress: progress) }
            catch { await TronLog.shared.flush(); throw error }
            await TronLog.shared.flush()
        } else {
            guard serviceEnabled(), try await readRuntime()?.pid == nil else { throw Failure.unmanaged }
            if let identity = attempt?.identity, Self.processExists(identity.pid) {
                throw Failure.observation
            }
        }
        await progress("Gateway process retired; retiring native helper")
        try await retireNativeHost()
    }

    private func stopOwnedRuntime(progress: @escaping @Sendable (String) async -> Void) async throws {
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
            attempt = (identity, "mac-quit-\(UUID().uuidString.lowercased())", nil)
        }
        let commandID = attempt!.commandID
        let startedAt = ContinuousClock.now
        var outcome = "blocked"
        defer {
            let elapsed = startedAt.duration(to: .now).components
            TronLog.shared.record(
                outcome == "blocked" ? .error : .info,
                event: "app.quit.gateway-exit", source: "lifecycle",
                message: "Coordinated Gateway stop finished",
                commandId: commandID, pid: identity.pid,
                elapsedMs: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                outcome: outcome
            )
        }
        if attempt!.response == nil {
            attempt!.response = try await stopGateway(attempt!.commandID)
        }
        let drainID = attempt!.response!.drainId
        var shutdownObservedAt: ContinuousClock.Instant?
        var observationLostAt: ContinuousClock.Instant?
        var identityLostAt: ContinuousClock.Instant?
        let clock = ContinuousClock()
        while true {
            let current = try await readRuntime()
            guard let currentPID = current?.pid else {
                guard !Self.processExists(identity.pid) else { throw Failure.observation }
                break
            }
            guard let current else { throw Failure.observation }
            guard currentPID == identity.pid else { throw Failure.runtimeReplaced }
            let observedStart = await processStartIdentity(currentPID)
            if let observedStart, observedStart != identity.start { throw Failure.runtimeReplaced }
            if current.processCommand != identity.command || observedStart == nil {
                identityLostAt = identityLostAt ?? clock.now
                if identityLostAt!.duration(to: clock.now) >= exitStallGrace { throw Failure.observation }
                try await wait()
                continue
            }
            identityLostAt = nil
            if await shutdownCompleted(identity.pid, drainID) {
                let observedAt = shutdownObservedAt ?? clock.now
                shutdownObservedAt = observedAt
                if observedAt.duration(to: clock.now) >= exitStallGrace {
                    TronLog.shared.record(
                        .warning, event: "app.quit.gateway-exit-stalled", source: "lifecycle",
                        message: "Gateway completed intentional shutdown; retiring its exact stalled job without relaunch",
                        commandId: attempt?.commandID, why: "pid=\(identity.pid)", outcome: "recovering"
                    )
                    await progress("Shutdown completed; waiting for launchd to retire the stalled Gateway")
                    try await retireCompletedGateway(identity.pid, identity.command, identity.start)
                    outcome = "recovered"
                    return
                }
            } else {
                do {
                    let drain = try await readDrain()
                    guard drain.drainId == drainID else { throw Failure.runtimeReplaced }
                    guard drain.phase != "failed" else {
                        attempt = nil
                        throw Failure.observation
                    }
                    if drain.phase == "preparing" || drain.phase == "waiting" {
                        observationLostAt = nil
                    } else {
                        observationLostAt = observationLostAt ?? clock.now
                    }
                } catch let failure as Failure {
                    throw failure
                } catch {
                    observationLostAt = observationLostAt ?? clock.now
                }
                if let lostAt = observationLostAt, lostAt.duration(to: clock.now) >= exitStallGrace {
                    TronLog.shared.record(
                        .error, event: "app.quit.gateway-observation-lost", source: "lifecycle",
                        message: "Could not observe the accepted stop drain or its completion receipt; process remains untouched",
                        commandId: attempt?.commandID, why: "pid=\(identity.pid)", outcome: "blocked"
                    )
                    throw Failure.observation
                }
            }
            try await wait()
        }
        outcome = "clean"
    }

    static func retireCompletedGateway(label: String, pid: Int, command: String, start: String) async throws {
        guard let current = try await LaunchAgentRuntimeReader.read(label: label),
              current.pid == pid, current.processCommand == command,
              await ServerProcessProbe.processStartIdentity(pid: pid) == start else {
            if !processExists(pid), try await LaunchAgentRuntimeReader.read(label: label)?.pid == nil { return }
            throw Failure.runtimeReplaced
        }
        guard let seconds = current.exitTimeoutSeconds, (1...120).contains(seconds) else {
            throw Failure.retirementPolicy
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds + 5))
        TronLog.shared.record(.info, event: "app.quit.gateway-retirement", source: "lifecycle",
            message: "Waiting for launchd retirement (exit timeout \(seconds)s plus 5s observation margin)",
            pid: pid, outcome: "waiting")
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", "gui/\(getuid())/\(label)"], policy: .acceptedOperation,
            timeoutSeconds: 5
        )
        if result.exitCode != 0 {
            TronLog.shared.record(.warning, event: "app.quit.gateway-bootout-uncertain", source: "lifecycle",
                message: "launchctl removal returned \(result.exitCode): \(result.stderr); observing the captured process without replay",
                pid: pid, outcome: "waiting")
        }
        while true {
            let runtime = try await LaunchAgentRuntimeReader.read(label: label)
            if let replacement = runtime?.pid, replacement != pid { throw Failure.runtimeReplaced }
            if !processExists(pid), runtime?.pid == nil { return }
            if processExists(pid) {
                if let observed = await ServerProcessProbe.processStartIdentity(pid: pid), observed != start {
                    throw Failure.runtimeReplaced
                }
            }
            guard ContinuousClock.now < deadline else { throw Failure.exitStalled }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func processExists(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno != ESRCH
    }

    static func hasCompletedShutdown(pid: Int, drainID: String, receiptURL: URL) async -> Bool {
        struct Receipt: Decodable { let version: Int; let pid: Int; let drainId: String }
        return await Task.detached(priority: .utility) {
            let descriptor = open(receiptURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= 4096 else { return false }
            guard let data = try? handle.read(upToCount: 4097), data.count <= 4096,
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
            return receipt.version == 1 && receipt.pid == pid && receipt.drainId == drainID
        }.value
    }

    static func shouldCoordinate(mode: MacStartupMode, ownsLock: Bool, canManage: Bool) -> Bool {
        ownsLock && canManage && (mode == .onboarded || mode == .wizard)
    }
}
