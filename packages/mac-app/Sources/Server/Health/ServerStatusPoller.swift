import Foundation

/// Periodic `system::ping` poller that drives the menu bar's status
/// icon. Emits a `ServerStatusSnapshot` every 30 s (configurable).
struct ServerStatusPoller: Sendable {
    private let setup: EnvironmentSetup
    private let interval: TimeInterval

    init(setup: EnvironmentSetup, interval: TimeInterval = 30) {
        self.setup = setup
        self.interval = interval
    }

    /// Returns a latest-only `AsyncStream` that emits an immediate snapshot on
    /// subscription, then one snapshot per `interval`. A stalled menu consumer
    /// retains only the newest status, and cancellation stops the timer.
    func snapshots() -> AsyncStream<ServerStatusSnapshot> {
        let setup = self.setup
        let interval = self.interval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
                    continuation.yield(snapshot)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Performs a single status probe synchronously. Used by tests +
    /// the wizard's "wait for Tron" loop. The state mapping mirrors
    /// the INVARIANT documented on `ServerPingResult`.
    static func singleSnapshot(setup: EnvironmentSetup) async -> ServerStatusSnapshot {
        let token = setup.readBearerToken()
        let result = await setup.pingServer(token)
        switch result {
        case .success(let info):
            let port = setup.serverPort
            let runtimeInfo = await setup.launchAgentManager.runtimeInfo(label: setup.launchAgentLabel)
            return ServerStatusSnapshot(
                state: .running(version: info.version, port: port),
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                processID: runtimeInfo?.pid,
                uptime: runtimeInfo?.uptime
            )
        case .unauthorized:
            return ServerStatusSnapshot(
                state: .unauthorized,
                tailscaleIP: setup.readTailscaleIPFromSettings()
            )
        case .unreachable:
            return await launchdStateSnapshot(setup: setup, reason: "unreachable")
        case .timeout:
            return await launchdStateSnapshot(setup: setup, reason: "timeout")
        case .malformedResponse:
            return await launchdStateSnapshot(setup: setup, reason: "malformed response")
        }
    }

    private static func launchdStateSnapshot(setup: EnvironmentSetup, reason: String) async -> ServerStatusSnapshot {
        let isLoaded = await setup.launchAgentManager.isLoaded(label: setup.launchAgentLabel)
        return ServerStatusSnapshot(
            state: isLoaded ? .failed(reason: reason) : .paused,
            tailscaleIP: setup.readTailscaleIPFromSettings()
        )
    }
}
