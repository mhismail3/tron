import Foundation

enum StableGatewayObserver {
    struct Admission: Equatable, Sendable {
        let processID: Int
        let uptime: String?
        let payload: GatewayPayloadValidationResult
        let info: ServerPingInfo

        static func == (lhs: Admission, rhs: Admission) -> Bool {
            lhs.processID == rhs.processID
                && lhs.payload == rhs.payload
                && lhs.info == rhs.info
        }
    }

    enum Refusal: String, Error, Equatable, Sendable {
        case serviceNotEnabled = "the Tron Agent Login Items service is not enabled"
        case noRuntime = "launchd reports no running Gateway process"
        case noPayload = "neither the selected nor the bundled Gateway payload validates"
        case listener = "the launchd Gateway process is not the only listener on the Gateway port"
        case processCommand = "the Gateway command line is not the one this app's launcher execs"
        case launchIdentity = "the Gateway was not started by this app's helper with its supervision and channel markers"
        case authenticatedIdentity = "the Gateway's authenticated identity does not match its payload manifest"
    }

    static func observe(
        info: ServerPingInfo,
        manager: LiveLaunchAgentManager = LiveLaunchAgentManager(profile: .stable),
        fileManager: FileManager = .default
    ) async -> Result<Admission, Refusal> {
        guard ExistingInstallDetector.serviceStatus(label: TronGatewayProfile.stable.launchAgentLabel) == .enabled else {
            return .failure(.serviceNotEnabled)
        }
        guard let runtime = await manager.runtimeInfo(label: TronGatewayProfile.stable.launchAgentLabel),
              let pid = runtime.pid else { return .failure(.noRuntime) }
        guard let payload = activePayload(fileManager: fileManager) else { return .failure(.noPayload) }
        let listeners = await ServerProcessProbe.listenerPIDs(port: TronGatewayProfile.stable.port)
        if let refused = refusal(
            runtimeInfo: runtime,
            listenerPIDs: listeners,
            payload: payload,
            info: info,
            expectedHelperPath: TronPaths.serverHelperBinary(profile: .stable).path
        ) { return .failure(refused) }
        return .success(Admission(processID: pid, uptime: runtime.uptime, payload: payload, info: info))
    }

    static func revalidatePairingAdmission(
        pinned: Admission,
        token: String?,
        ping: @escaping @Sendable (String?) async -> ServerPingResult,
        admit: @escaping @Sendable (ServerPingInfo) async -> Admission?
    ) async -> Admission? {
        guard case .success(let info) = await ping(token),
              let current = await admit(info),
              current == pinned else { return nil }
        return current
    }

    static func activePayload(fileManager: FileManager = .default) -> GatewayPayloadValidationResult? {
        let external = GatewayPayloadValidator.validateSelection(
            store: GatewayPayloadStore(
                home: TronPaths.tronHome(profile: .stable),
                channel: TronGatewayProfile.stable.channel
            ),
            fileManager: fileManager
        )
        let bundled = GatewayPayloadValidator.validate(
            payloadRoot: TronPaths.gatewayPayloadRoot,
            expectedChannel: TronGatewayProfile.stable.channel,
            fileManager: fileManager
        )
        return GatewayPayloadResolver.resolve(external: external, bundled: bundled)
    }

    struct RuntimeFence: Equatable, Sendable {
        let process: LaunchAgentProcessFence
        let selection: PayloadSelectionStamp
        let manifest: PayloadSelectionStamp
        let bundledManifest: PayloadSelectionStamp

        static func read(
            label: String,
            store: GatewayPayloadStore,
            bundledPayloadRoot: URL,
            processFence: @Sendable (String) async -> LaunchAgentProcessFence? = {
                await LaunchAgentRuntimeReader.readProcessFence(label: $0)
            }
        ) async -> Self? {
            guard let process = await processFence(label),
                  let selection = PayloadSelectionStamp.read(store.currentManifestURL),
                  let bundled = PayloadSelectionStamp.read(
                      bundledPayloadRoot.appendingPathComponent("manifest.json")
                  ),
                  let manifest = manifestStamp(selection: selection, store: store, bundled: bundled) else {
                return nil
            }
            return Self(process: process, selection: selection, manifest: manifest, bundledManifest: bundled)
        }

        private static func manifestStamp(
            selection: PayloadSelectionStamp,
            store: GatewayPayloadStore,
            bundled: PayloadSelectionStamp
        ) -> PayloadSelectionStamp? {
            guard let version = selectedVersion(selection) else { return bundled }
            guard let selected = PayloadSelectionStamp.read(
                store.versionRoot(version).appendingPathComponent("manifest.json")
            ) else { return nil }
            return selected.exists ? selected : bundled
        }

        private static func selectedVersion(_ stamp: PayloadSelectionStamp) -> String? {
            guard stamp.exists,
                  let selection = try? JSONDecoder().decode(GatewayPayloadSelection.self, from: stamp.bytes),
                  GatewayPayloadStore.validComponent(
                    selection.version, maximumLength: GatewayPayloadStore.versionComponentLimit
                  ) else { return nil }
            return selection.version
        }
    }

    static func refusal(
        runtimeInfo: LaunchAgentRuntimeInfo?,
        listenerPIDs: Set<Int>,
        payload: GatewayPayloadValidationResult,
        info: ServerPingInfo,
        expectedHelperPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Refusal? {
        let profile = TronGatewayProfile.stable
        guard let runtimeInfo, let pid = runtimeInfo.pid else { return .noRuntime }
        guard listenerPIDs == Set([pid]) else { return .listener }
        guard StableGatewayProvenance.processCommand(
            runtimeInfo.processCommand, owns: payload.root, expectedHost: "tailscale", profile: profile
        ) else { return .processCommand }
        guard StableGatewayProvenance.validates(
            runtimeInfo, payload: payload, expectedHelperPath: expectedHelperPath, fileExists: fileExists
        ) else { return .launchIdentity }
        guard authenticatedIdentity(info, matches: payload.manifest, channel: profile.channel) else {
            return .authenticatedIdentity
        }
        return nil
    }

    static func authenticatedIdentity(
        _ info: ServerPingInfo,
        matches manifest: GatewayPayloadManifest,
        channel: String
    ) -> Bool {
        guard let sourceRevision = manifest.sourceRevision,
              let runtimeEpoch = manifest.runtimeEpoch else { return false }
        return info.version == manifest.gatewayVersion
            && info.gatewayChannel == channel
            && info.sourceRevision == sourceRevision
            && info.runtimeEpoch == runtimeEpoch
            && info.buildFingerprint == manifest.payloadFingerprint
    }


}
