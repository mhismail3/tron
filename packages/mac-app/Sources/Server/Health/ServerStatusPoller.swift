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
                    guard !Task.isCancelled else { break }
                    continuation.yield(snapshot)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch is CancellationError {
                        break
                    }
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
        guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
        let token = setup.readBearerToken()
        if setup.profile == .debug {
            switch await setup.observeDebugGateway(token) {
            case .admitted(let admission):
                guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
                return ServerStatusSnapshot(
                    state: .running(version: admission.info.version, port: setup.serverPort),
                    tailscaleIP: admission.pairingTransportAvailable ? admission.transportHost : nil,
                    processID: admission.processID,
                    uptime: admission.uptime,
                    debugAdmission: admission
                )
            case .unauthorized:
                return ServerStatusSnapshot(state: .unauthorized)
            case .unavailable:
                return ServerStatusSnapshot(state: .paused)
            }
        }

        let result = await setup.pingServer(token)
        guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
        switch result {
        case .success(let info):
            let admission = await setup.admitStableRuntime(info)
            guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
            let installationState: ServerStatusState
            if admission != nil {
                installationState = .running(version: info.version, port: setup.serverPort)
            } else {
                installationState = .needsRepair(
                    version: info.version,
                    port: setup.serverPort,
                    reason: "Installed app, listener, selected payload, and authenticated runtime do not match"
                )
            }
            return ServerStatusSnapshot(
                state: installationState,
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                processID: admission?.processID,
                uptime: admission?.uptime
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
