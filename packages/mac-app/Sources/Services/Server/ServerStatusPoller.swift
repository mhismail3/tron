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
    /// the wizard's "wait for server" loop.
    static func singleSnapshot(setup: EnvironmentSetup) async -> ServerStatusSnapshot {
        let token = setup.readBearerToken()
        let info = await setup.pingServer(token)
        if let info {
            return ServerStatusSnapshot(
                tone: .running,
                version: info.version,
                port: info.port,
                tailscaleIP: info.tailscaleIp ?? setup.readTailscaleIPFromSettings(),
                bearerToken: token
            )
        }
        // Distinguish "no token" (unauthorized) from "no server" (stopped).
        let tone: MenuBarTone = (token == nil) ? .stopped : .unauthorized
        return ServerStatusSnapshot(
            tone: tone,
            version: nil,
            port: setup.serverPort,
            tailscaleIP: setup.readTailscaleIPFromSettings(),
            bearerToken: token
        )
    }
}
