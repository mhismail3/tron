import Darwin
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
    private let shutdownCompleted: @Sendable (Int, String) async -> Bool
    private let readDrain: @Sendable () async throws -> GatewayStopClient.Drain
    private let exitStallGrace: Duration = .seconds(5)
    private let stopGateway: @Sendable (String) async throws -> GatewayStopClient.Response
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
            attempt = (identity, "mac-quit-\(UUID().uuidString.lowercased())", nil)
        }
        // A retry after uncertainty reuses this exact runtime's receipt. There is
        // no automatic replay and a different runtime always gets a new attempt.
        if attempt!.response == nil {
            attempt!.response = try await stopGateway(attempt!.commandID)
        }
        let drainID = attempt!.response!.drainId
        var shutdownObservedAt: ContinuousClock.Instant?
        var observationLostAt: ContinuousClock.Instant?
        let clock = ContinuousClock()
        while true {
            let current = try await readRuntime()
            guard let current else { break }
            guard let currentPID = current.pid else { break }
            guard currentPID == identity.pid else { throw Failure.runtimeReplaced }
            guard current.processCommand == identity.command,
                  await processStartIdentity(currentPID) == identity.start else {
                // Exit can race the separate supervisor/ps observations. Confirm
                // absence before classifying a disappearing process as replaced.
                if try await readRuntime()?.pid == nil { break }
                throw Failure.runtimeReplaced
            }
            if await shutdownCompleted(identity.pid, drainID) {
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
            } else {
                // A missing receipt is not evidence that accepted work finished.
                // Keep a reachable canonical drain unbounded; loss of observation
                // fails the UI only, never cancels work or signals the process.
                do {
                    let drain = try await readDrain()
                    guard drain.drainId == drainID else { throw Failure.runtimeReplaced }
                    guard drain.phase != "failed" else {
                        attempt = nil // an explicit retry may start a new failed-drain attempt
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
    }

    static func hasCompletedShutdown(pid: Int, drainID: String, receiptURL: URL) async -> Bool {
        struct Receipt: Decodable { let version: Int; let pid: Int; let drainId: String }
        return await Task.detached(priority: .utility) {
            // Reject non-regular/symlink receipts without blocking on a FIFO or
            // following a replacement path. The producer publishes regular files.
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
