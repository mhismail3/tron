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
        let uptime: String?
        let payload: GatewayPayloadValidationResult
        let info: ServerPingInfo
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
                port: profile.port
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

    static func processCommand(_ command: String?, owns root: URL, port: Int) -> Bool {
        guard let command else { return false }
        let fields = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 6 else { return false }
        let payloadRoot = root.standardizedFileURL.path
        guard fields[0] == "\(payloadRoot)/runtime/node-arm64"
                || fields[0] == "\(payloadRoot)/runtime/node-x64",
              fields[1] == "\(payloadRoot)/app/dist/index.js",
              argument("--port", in: fields) == String(port) else { return false }
        return true
    }

    private static func argument(_ name: String, in fields: [String]) -> String? {
        guard let index = fields.firstIndex(of: name), fields.indices.contains(index + 1) else { return nil }
        return fields[index + 1]
    }
}
