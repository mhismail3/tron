import Foundation

/// What one fail-closed Stable probe concluded for the status poll.
enum StableProbe: Equatable, Sendable {
    case admitted(StableGatewayObserver.Admission)
    /// Admission was refused by `refusal`. `selected` is the selected payload's
    /// verdict, or nil when the selection itself does not validate.
    case refused(StableGatewayObserver.Refusal, selected: GatewayPayloadValidationResult?)
}

/// Reuses one admitted probe while the runtime fence and the authenticated ping
/// identity are unchanged.
///
/// The probe reads both payload trees (≈1.2 GB on this Mac) and spawns `lsof`
/// plus two `ps` display reads, so the 30 s poll must not pay it per cycle. The
/// per-cycle authenticated ping stays: it is the liveness probe that decides
/// Running. A fence that cannot be read always re-probes, and a refusal is
/// never reused, so one transient `lsof` failure or an update restart landing
/// between the ping and the fence read cannot pin "needs repair" for the
/// process's lifetime.
actor StableProbeCache {
    /// How one cycle resolves the fail-closed probe.
    enum Mode: Sendable {
        /// A 30 s poll cycle: reuse an admission while the runtime fence and the
        /// authenticated ping identity are unchanged.
        case reusable
        /// An explicit user action: always run the full probe and record its
        /// outcome, so a failure it finds cannot be overwritten by the next
        /// cycle's reused admission.
        case explicit
    }

    private let runtimeFence: @Sendable () async -> StableGatewayObserver.RuntimeFence?
    private let fullProbe: @Sendable (ServerPingInfo) async -> StableProbe
    private var entry: (fence: StableGatewayObserver.RuntimeFence, admission: StableGatewayObserver.Admission)?

    init(
        runtimeFence: @escaping @Sendable () async -> StableGatewayObserver.RuntimeFence?,
        fullProbe: @escaping @Sendable (ServerPingInfo) async -> StableProbe
    ) {
        self.runtimeFence = runtimeFence
        self.fullProbe = fullProbe
    }

    func probe(info: ServerPingInfo, mode: Mode) async -> StableProbe {
        guard let fence = await runtimeFence() else {
            let probe = await fullProbe(info)
            // A refusal found without a fence is still a refusal: an older
            // admission must not stay replayable behind it.
            if case .refused = probe { entry = nil }
            return probe
        }
        // The ping identity is the only per-cycle link between whoever answered
        // and the admitted runtime now that `lsof` is skipped between polls, so
        // a changed identity re-admits.
        if mode == .reusable, let entry, entry.fence == fence, entry.admission.info == info {
            return .admitted(Self.republished(entry.admission, uptime: fence.process.elapsedTime))
        }
        let probe = await fullProbe(info)
        // Both modes record: an explicit user action's refusal must replace the
        // admission the next cycle would otherwise replay, and its admission
        // may be reused by the cycles that follow it.
        switch probe {
        case .admitted(let admission): entry = (fence, admission)
        case .refused: entry = nil
        }
        return probe
    }

    /// The cached admission carries the uptime of the probe that admitted it,
    /// which may be days old. The fence re-reads the process's elapsed time
    /// every cycle, so publish that instead: a reused admission would otherwise
    /// freeze the menu's uptime and snap it backwards on each poll.
    private static func republished(
        _ admission: StableGatewayObserver.Admission,
        uptime: String
    ) -> StableGatewayObserver.Admission {
        StableGatewayObserver.Admission(
            processID: admission.processID,
            uptime: uptime,
            payload: admission.payload,
            info: admission.info
        )
    }
}

/// Periodic `system::ping` poller that drives the menu bar's status
/// icon. Emits a `ServerStatusSnapshot` every 30 s (configurable).
struct ServerStatusPoller: Sendable {
    private let setup: EnvironmentSetup
    private let interval: TimeInterval
    /// One admission cache for this poller's life: the 30 s stream and the
    /// explicit user actions share it, so a refusal an explicit probe finds is
    /// not overwritten by the next cycle's reused admission.
    private let probeCache: StableProbeCache
    /// The stream's per-cycle ping; it is the only ping that reuses one bounded
    /// Tailscale resolution. Explicit actions go through `setup.pingServer`,
    /// which resolves live.
    private let statusPollPing: @Sendable (String?) async -> ServerPingResult

    init(
        setup: EnvironmentSetup,
        interval: TimeInterval = 30,
        runtimeFence: (@Sendable () async -> StableGatewayObserver.RuntimeFence?)? = nil
    ) {
        self.setup = setup
        self.interval = interval
        self.statusPollPing = setup.statusPollPingServer ?? setup.pingServer
        self.probeCache = StableProbeCache(
            runtimeFence: runtimeFence ?? {
                await StableGatewayObserver.RuntimeFence.read(
                    label: setup.launchAgentLabel,
                    store: GatewayPayloadStore(home: setup.tronHome, channel: setup.profile.channel),
                    bundledPayloadRoot: TronPaths.gatewayPayloadRoot
                )
            },
            fullProbe: { info in await ServerStatusPoller.fullProbe(setup: setup, info: info) }
        )
    }

    /// Returns a latest-only `AsyncStream` that emits an immediate snapshot on
    /// subscription, then one snapshot per `interval`. A stalled menu consumer
    /// retains only the newest status, and cancellation stops the timer.
    func snapshots() -> AsyncStream<ServerStatusSnapshot> {
        let setup = self.setup
        let interval = self.interval
        let probeCache = self.probeCache
        let pingServer = self.statusPollPing
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let snapshot = await ServerStatusPoller.singleSnapshot(
                        setup: setup, probeCache: probeCache, probeMode: .reusable, pingServer: pingServer
                    )
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

    /// The full fail-closed probe for one explicit user action, recorded in the
    /// poller's shared admission cache. Menu presentation and post-action
    /// refreshes use this, so a failure they find is not overwritten by the next
    /// 30 s cycle's reused admission.
    func explicitSnapshot() async -> ServerStatusSnapshot {
        await ServerStatusPoller.singleSnapshot(
            setup: setup, probeCache: probeCache, probeMode: .explicit
        )
    }

    /// One cycle of the poll. `probeCache` may reuse an admission while the
    /// runtime fence is unchanged; `probeMode` decides whether this cycle may
    /// reuse one or must run the full probe and record it. `pingServer` is the
    /// cycle's transport ping: the poll passes its bounded-resolution ping, and
    /// a nil value (explicit user actions, startup, restart wait) resolves live.
    static func singleSnapshot(
        setup: EnvironmentSetup,
        probeCache: StableProbeCache? = nil,
        probeMode: StableProbeCache.Mode = .reusable,
        pingServer: (@Sendable (String?) async -> ServerPingResult)? = nil
    ) async -> ServerStatusSnapshot {
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

        let result = await (pingServer ?? setup.pingServer)(token)
        guard !Task.isCancelled else { return ServerStatusSnapshot(state: .checking) }
        switch result {
        case .success(let info):
            let probe: StableProbe
            if let probeCache {
                probe = await probeCache.probe(info: info, mode: probeMode)
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
            case .refused(let refusal, let selected):
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
                        reason: "Stable admission refused: \(refusal.rawValue)"
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
        let refusal: StableGatewayObserver.Refusal
        switch await setup.admitStableRuntime(info) {
        case .success(let admission): return .admitted(admission)
        case .failure(let refused): refusal = refused
        }
        guard setup.profile.channel == "stable", info.buildFingerprint != nil else {
            return .refused(refusal, selected: nil)
        }
        let store = GatewayPayloadStore(home: setup.tronHome, channel: setup.profile.channel)
        guard case .success(let selected) = GatewayPayloadValidator.validateSelection(store: store) else {
            return .refused(refusal, selected: nil)
        }
        return .refused(refusal, selected: selected)
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
