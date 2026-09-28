import Foundation

/// What one fail-closed Stable probe concluded for the status poll.
enum StableProbe: Equatable, Sendable {
    case admitted(StableGatewayObserver.Admission)
    /// Admission was refused. `selected` is the selected payload's verdict, or
    /// nil when the selection itself does not validate.
    case refused(selected: GatewayPayloadValidationResult?)
}

/// Reuses one fail-closed Stable probe while the runtime fence is unchanged.
///
/// The probe reads both payload trees (≈1.2 GB on this Mac) and spawns `lsof`
/// plus two `ps` display reads, so the 30 s poll must not pay it per cycle. The
/// per-cycle authenticated ping stays: it is the liveness probe that decides
/// Running. A fence that cannot be read always re-probes, so reuse can never
/// outlive a lost proof.
actor StableProbeCache {
    private let runtimeFence: @Sendable () async -> StableGatewayObserver.RuntimeFence?
    private let fullProbe: @Sendable (ServerPingInfo) async -> StableProbe
    private var entry: (fence: StableGatewayObserver.RuntimeFence, probe: StableProbe)?

    init(
        runtimeFence: @escaping @Sendable () async -> StableGatewayObserver.RuntimeFence?,
        fullProbe: @escaping @Sendable (ServerPingInfo) async -> StableProbe
    ) {
        self.runtimeFence = runtimeFence
        self.fullProbe = fullProbe
    }

    func probe(info: ServerPingInfo) async -> StableProbe {
        guard let fence = await runtimeFence() else { return await fullProbe(info) }
        if let entry, entry.fence == fence { return entry.probe }
        let probe = await fullProbe(info)
        entry = (fence, probe)
        return probe
    }
}

/// Periodic `system::ping` poller that drives the menu bar's status
/// icon. Emits a `ServerStatusSnapshot` every 30 s (configurable).
struct ServerStatusPoller: Sendable {
    private let setup: EnvironmentSetup
    private let interval: TimeInterval
    /// The status poll's runtime fence. It reads launchd's pid and that
    /// process's start identity, so a restart under the same payload cannot
    /// keep a stale admission. A fence that cannot be read re-probes.
    private let runtimeFence: @Sendable () async -> StableGatewayObserver.RuntimeFence?

    init(
        setup: EnvironmentSetup,
        interval: TimeInterval = 30,
        runtimeFence: (@Sendable () async -> StableGatewayObserver.RuntimeFence?)? = nil
    ) {
        self.setup = setup
        self.interval = interval
        self.runtimeFence = runtimeFence ?? {
            await StableGatewayObserver.RuntimeFence.read(
                label: setup.launchAgentLabel,
                store: GatewayPayloadStore(home: setup.tronHome, channel: setup.profile.channel),
                bundledPayloadRoot: TronPaths.gatewayPayloadRoot
            )
        }
    }

    /// Returns a latest-only `AsyncStream` that emits an immediate snapshot on
    /// subscription, then one snapshot per `interval`. A stalled menu consumer
    /// retains only the newest status, and cancellation stops the timer.
    func snapshots() -> AsyncStream<ServerStatusSnapshot> {
        let setup = self.setup
        let interval = self.interval
        let runtimeFence = self.runtimeFence
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let probeCache = StableProbeCache(
                    runtimeFence: runtimeFence,
                    fullProbe: { info in await ServerStatusPoller.fullProbe(setup: setup, info: info) }
                )
                while !Task.isCancelled {
                    let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
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

    /// Performs a single status probe synchronously, with the full fail-closed
    /// Stable probe. Used by explicit user actions (menu presentation, restart
    /// wait, startup) and by the wizard's "wait for Tron" loop.
    static func singleSnapshot(setup: EnvironmentSetup) async -> ServerStatusSnapshot {
        await singleSnapshot(setup: setup, probeCache: nil)
    }

    /// One cycle of the poll. `probeCache` may reuse an admission while the
    /// runtime fence is unchanged; explicit user actions pass none.
    static func singleSnapshot(setup: EnvironmentSetup, probeCache: StableProbeCache?) async -> ServerStatusSnapshot {
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
            let probe: StableProbe
            if let probeCache {
                probe = await probeCache.probe(info: info)
            } else {
                probe = await fullProbe(setup: setup, info: info)
            }
            guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
            let installationState: ServerStatusState
            let processID: Int?
            let uptime: String?
            switch probe {
            case .admitted(let admission):
                installationState = .running(version: info.version, port: setup.serverPort)
                processID = admission.processID
                uptime = admission.uptime
            case .refused(let selected):
                processID = nil
                uptime = nil
                if setup.profile.channel == "stable",
                   let running = info.buildFingerprint,
                   let selected,
                   running != selected.manifest.payloadFingerprint {
                    installationState = .updateIncomplete(
                        running: String(running.prefix(12)), selected: selected.manifest.version
                    )
                } else {
                    installationState = .needsRepair(
                        version: info.version,
                        port: setup.serverPort,
                        reason: "Installed app, listener, selected payload, and authenticated runtime do not match"
                    )
                }
            }
            return ServerStatusSnapshot(
                state: installationState,
                tailscaleIP: setup.readTailscaleIPFromSettings(),
                processID: processID,
                uptime: uptime
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

    /// One fail-closed Stable probe: the admission, plus — when it refuses — the
    /// selected payload's verdict that tells an in-progress update from a repair.
    static func fullProbe(setup: EnvironmentSetup, info: ServerPingInfo) async -> StableProbe {
        if let admission = await setup.admitStableRuntime(info) { return .admitted(admission) }
        guard setup.profile.channel == "stable", info.buildFingerprint != nil else {
            return .refused(selected: nil)
        }
        let store = GatewayPayloadStore(home: setup.tronHome, channel: setup.profile.channel)
        guard case .success(let selected) = GatewayPayloadValidator.validateSelection(store: store) else {
            return .refused(selected: nil)
        }
        return .refused(selected: selected)
    }

    private static func launchdStateSnapshot(setup: EnvironmentSetup, reason: String) async -> ServerStatusSnapshot {
        let isLoaded = await setup.launchAgentManager.isLoaded(label: setup.launchAgentLabel)
        guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
        return ServerStatusSnapshot(
            state: isLoaded == false ? .paused : .failed(reason: reason),
            tailscaleIP: setup.readTailscaleIPFromSettings()
        )
    }
}
