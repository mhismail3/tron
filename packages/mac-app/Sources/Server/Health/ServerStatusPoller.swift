import Foundation

enum StableProbe: Equatable, Sendable {
    case admitted(StableGatewayObserver.Admission)
    case refused(StableGatewayObserver.Refusal, selected: GatewayPayloadValidationResult?)
}

actor StableProbeCache {
    enum Mode: Sendable {
        case reusable
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
            if case .refused = probe { entry = nil }
            return probe
        }
        if mode == .reusable, let entry, entry.fence == fence, entry.admission.info == info {
            return .admitted(Self.republished(entry.admission, uptime: fence.process.elapsedTime))
        }
        let probe = await fullProbe(info)
        switch probe {
        case .admitted(let admission): entry = (fence, admission)
        case .refused: entry = nil
        }
        return probe
    }

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

struct ServerStatusPoller: Sendable {
    private let setup: EnvironmentSetup
    private let interval: TimeInterval
    private let probeCache: StableProbeCache
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

    func explicitSnapshot() async -> ServerStatusSnapshot {
        await ServerStatusPoller.singleSnapshot(
            setup: setup, probeCache: probeCache, probeMode: .explicit
        )
    }

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
