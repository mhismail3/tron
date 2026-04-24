import Foundation

/// Periodic `system.ping` poller that drives the menu bar's status
/// icon. Emits a `ServerStatusSnapshot` every 30 s (configurable).
///
/// Marked actor so multiple readers can `snapshots()` safely (in
/// practice only the menu bar consumes it; the actor is for
/// future-proofing the diagnostics page).
actor ServerStatusPoller {
    private let setup: EnvironmentSetup
    private let interval: TimeInterval

    init(setup: EnvironmentSetup, interval: TimeInterval = 30) {
        self.setup = setup
        self.interval = interval
    }

    /// Returns an `AsyncStream` that emits an immediate snapshot on
    /// subscription, then one snapshot per `interval`. Cancellation
    /// stops the timer.
    func snapshots() -> AsyncStream<ServerStatusSnapshot> {
        let setup = self.setup
        let interval = self.interval
        return AsyncStream { continuation in
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
    /// the wizard's "wait for server" loop. The tone mapping mirrors
    /// the INVARIANT documented on `ServerPingResult`.
    static func singleSnapshot(setup: EnvironmentSetup) async -> ServerStatusSnapshot {
        let token = setup.readBearerToken()
        let result = await setup.pingServer(token)
        switch result {
        case .success(let info):
            return ServerStatusSnapshot(
                tone: .running,
                version: info.version,
                port: info.port,
                tailscaleIP: info.tailscaleIp ?? setup.readTailscaleIPFromSettings(),
                bearerToken: token
            )
        case .unauthorized:
            return ServerStatusSnapshot(
                tone: .unauthorized,
                version: nil,
                port: setup.serverPort,
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                bearerToken: token
            )
        case .unreachable, .timeout:
            return ServerStatusSnapshot(
                tone: .stopped,
                version: nil,
                port: setup.serverPort,
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                bearerToken: token
            )
        case .malformedResponse:
            return ServerStatusSnapshot(
                tone: .unknown,
                version: nil,
                port: setup.serverPort,
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                bearerToken: token
            )
        }
    }
}
