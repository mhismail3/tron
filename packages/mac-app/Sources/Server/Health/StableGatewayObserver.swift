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
              runtimeInfo.parentBundleIdentifier == MacRuntimeVariant.releaseBundleIdentifier,
              runtimeInfo.gatewaySupervisionMarker == TronPaths.gatewaySupervisionValue,
              runtimeInfo.gatewayChannelMarker == profile.channel,
              helperProvenance(
                runtimeInfo,
                expectedHelperPath: expectedHelperPath,
                fileExists: fileExists
              ),
              payload.manifest.channel == profile.channel,
              processCommand(
                runtimeInfo.processCommand,
                owns: payload.root,
                expectedHost: "tailscale",
                profile: profile
              ),
              authenticatedIdentity(info, matches: payload.manifest, channel: profile.channel) else {
            return false
        }
        return true
    }

    private static func helperProvenance(
        _ runtimeInfo: LaunchAgentRuntimeInfo,
        expectedHelperPath: String,
        fileExists: (String) -> Bool
    ) -> Bool {
        let expected = URL(fileURLWithPath: expectedHelperPath).standardizedFileURL.path
        guard fileExists(expected) else { return false }
        if let executable = runtimeInfo.executablePath, !executable.isEmpty {
            return URL(fileURLWithPath: executable).standardizedFileURL.path == expected
        }
        guard let bundleProgram = runtimeInfo.bundleProgram,
              let contents = expected.range(of: "Contents/") else { return false }
        return bundleProgram == String(expected[contents.lowerBound...])
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

    static func processCommand(
        _ command: String?,
        owns root: URL,
        expectedHost: String,
        profile: TronGatewayProfile
    ) -> Bool {
        guard let command else { return false }
        let fields = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let payloadRoot = root.standardizedFileURL.path
        let normalizedHost = expectedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // launchd's exact arguments are the ownership contract. In
        // particular, do not accept a valid entrypoint from another payload
        // or a process carrying an unrelated port/flag suffix. Stable is
        // always Tailscale-bound; Debug may explicitly use loopback.
        guard (profile == TronGatewayProfile.stable && normalizedHost == "tailscale")
            || (profile == TronGatewayProfile.debug && (normalizedHost == "tailscale" || normalizedHost == "127.0.0.1")) else { return false }
        guard fields == [
            "\(payloadRoot)/runtime/node-arm64",
            "\(payloadRoot)/app/dist/index.js",
            "--host", normalizedHost, "--port", String(profile.port)
        ] || fields == [
            "\(payloadRoot)/runtime/node-x64",
            "\(payloadRoot)/app/dist/index.js",
            "--host", normalizedHost, "--port", String(profile.port)
        ] else { return false }
        return true
    }

}
