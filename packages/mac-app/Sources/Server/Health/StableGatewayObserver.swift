import Foundation

/// Coherent, fail-closed admission for the installed Stable Gateway.
///
/// One admission correlates ServiceManagement ownership, launchd's exact PID,
/// the only listener on 9847, the validated selected (or bundled fallback)
/// payload, the PID command line, and authenticated `system.info` provenance.
/// None of those projections is independently sufficient to report Running or
/// to issue a pairing invitation.
enum StableGatewayObserver {
    struct Admission: Equatable, Sendable {
        let processID: Int
        /// Display-only diagnostic. It deliberately does not participate in
        /// admission equality because elapsed time changes between otherwise
        /// identical observations.
        let uptime: String?
        let payload: GatewayPayloadValidationResult
        let info: ServerPingInfo

        static func == (lhs: Admission, rhs: Admission) -> Bool {
            lhs.processID == rhs.processID
                && lhs.payload == rhs.payload
                && lhs.info == rhs.info
        }
    }

    static func observe(
        info: ServerPingInfo,
        manager: LiveLaunchAgentManager = LiveLaunchAgentManager(profile: .stable),
        fileManager: FileManager = .default
    ) async -> Admission? {
        guard ExistingInstallDetector.serviceStatus(label: TronGatewayProfile.stable.launchAgentLabel) == .enabled,
              let runtime = await manager.runtimeInfo(label: TronGatewayProfile.stable.launchAgentLabel),
              let payload = activePayload(fileManager: fileManager) else { return nil }
        let listeners = await ServerProcessProbe.listenerPIDs(port: TronGatewayProfile.stable.port)
        guard validates(
            runtimeInfo: runtime,
            listenerPIDs: listeners,
            payload: payload,
            info: info,
            expectedHelperPath: TronPaths.serverHelperBinary(profile: .stable).path
        ), let pid = runtime.pid else { return nil }
        return Admission(processID: pid, uptime: runtime.uptime, payload: payload, info: info)
    }

    /// Re-pings and re-admits immediately before pairing data is read. A
    /// changed process, payload, or authenticated identity invalidates the
    /// presentation rather than allowing a stale QR code.
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

    /// The runtime fence an observer re-proves before it may reuse an admission:
    /// the live launchd process identity plus the payload selection stamps. It
    /// is a change detector — a changed selection or a changed process runs the
    /// full fail-closed check again.
    struct RuntimeFence: Equatable, Sendable {
        let process: LaunchAgentProcessFence
        let selection: PayloadSelectionStamp
        /// The active payload's manifest: the selected payload's when a readable
        /// selection names one, otherwise the bundled fallback's.
        let manifest: PayloadSelectionStamp

        /// Returns `nil` when launchd owns no such process, or when a file the
        /// fence must stamp exists but cannot be read safely. Such a fence would
        /// compare equal to the next unreadable one, so a caller that cannot
        /// prove the runtime runs the full check instead of reusing.
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
                  let manifest = manifestStamp(
                      selection: selection, store: store, bundledPayloadRoot: bundledPayloadRoot
                  ) else { return nil }
            return Self(process: process, selection: selection, manifest: manifest)
        }

        /// `nil` when a manifest the fence must stamp exists but cannot be read
        /// safely. An absent selected manifest falls back to the bundled one,
        /// matching `activePayload`'s resolution of the active payload.
        private static func manifestStamp(
            selection: PayloadSelectionStamp,
            store: GatewayPayloadStore,
            bundledPayloadRoot: URL
        ) -> PayloadSelectionStamp? {
            let bundled = PayloadSelectionStamp.read(bundledPayloadRoot.appendingPathComponent("manifest.json"))
            guard let version = selectedVersion(selection) else { return bundled }
            guard let selected = PayloadSelectionStamp.read(
                store.versionRoot(version).appendingPathComponent("manifest.json")
            ) else { return nil }
            return selected.exists ? selected : bundled
        }

        /// A path hint for the manifest leg only. The strict selection checks
        /// stay in `GatewayPayloadValidator.validateSelection`.
        private static func selectedVersion(_ stamp: PayloadSelectionStamp) -> String? {
            guard stamp.exists,
                  let selection = try? JSONDecoder().decode(GatewayPayloadSelection.self, from: stamp.bytes),
                  GatewayPayloadStore.validComponent(
                    selection.version, maximumLength: GatewayPayloadStore.versionComponentLimit
                  ) else { return nil }
            return selection.version
        }
    }

    static func validates(
        runtimeInfo: LaunchAgentRuntimeInfo?,
        listenerPIDs: Set<Int>,
        payload: GatewayPayloadValidationResult,
        info: ServerPingInfo,
        expectedHelperPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let profile = TronGatewayProfile.stable
        guard let runtimeInfo,
              let pid = runtimeInfo.pid,
              listenerPIDs == Set([pid]),
              StableGatewayProvenance.validates(runtimeInfo, payload: payload,
                  expectedHelperPath: expectedHelperPath, fileExists: fileExists),
              authenticatedIdentity(info, matches: payload.manifest, channel: profile.channel) else {
            return false
        }
        return true
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
