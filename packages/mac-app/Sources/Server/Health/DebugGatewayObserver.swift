import Darwin
import Foundation

/// Read-only admission for the developer-owned Gateway on port 9848.
///
/// The installed wrapper never manages this process. One immutable observation
/// reads one bounded lifecycle record, resolves that record's exact transport,
/// authenticates it, and correlates the live supervisor, child, listener,
/// selected immutable payload, process command, and runtime identity.
enum DebugGatewayObserver {
    static let maximumLifecycleBytes: Int64 = 64 * 1024

    struct Lifecycle: Codable, Equatable, Sendable {
        var lifecycle: String
        var expectedHost: String
        var expectedPort: Int
        var expectedHome: String
        var supervisorPid: Int
        var supervisorStartIdentity: String
        var childPid: Int
        var childStartIdentity: String
        var epoch: String
        var sourceRevision: String
        var buildFingerprint: String
    }

    struct Admission: Equatable, Sendable {
        let lifecycle: Lifecycle
        let processID: Int
        /// Display-only diagnostic. It deliberately does not participate in
        /// admission equality because elapsed time changes between otherwise
        /// identical observations.
        let uptime: String?
        let transportHost: String
        let pairingTransportAvailable: Bool
        let selectedPayload: GatewayPayloadValidationResult
        let info: ServerPingInfo

        static func == (lhs: Admission, rhs: Admission) -> Bool {
            lhs.lifecycle == rhs.lifecycle
                && lhs.processID == rhs.processID
                && lhs.transportHost == rhs.transportHost
                && lhs.pairingTransportAvailable == rhs.pairingTransportAvailable
                && lhs.selectedPayload == rhs.selectedPayload
                && lhs.info == rhs.info
        }
    }

    enum Observation: Equatable, Sendable {
        case admitted(Admission)
        case unauthorized
        case unavailable
    }

    static func lifecycleURL(home: URL) -> URL {
        home.appendingPathComponent("gateway/lifecycle.json", isDirectory: false)
    }

    static func observe(
        home: URL,
        token: String?,
        fileManager: FileManager = .default,
        resolveTailscale: @escaping @Sendable () async -> String? = {
            let status = await TailscaleProbe.probe()
            return status.displayIP
        },
        ping: @escaping @Sendable (String, Int, String?) async throws -> ServerPingResult = {
            try await ServerPing.ping(host: $0, port: $1, token: $2)
        }
    ) async -> Observation {
        guard let lifecycle = lifecycle(home: home, fileManager: fileManager),
              lifecycle.expectedHome == home.standardizedFileURL.path,
              lifecycle.expectedPort == TronGatewayProfile.debug.port,
              lifecycle.lifecycle == "ready" else { return .unavailable }

        let selected: GatewayPayloadValidationResult
        switch GatewayPayloadValidator.validateSelection(
            store: GatewayPayloadStore(home: home, channel: TronGatewayProfile.debug.channel),
            fileManager: fileManager
        ) {
        case .success(let value): selected = value
        case .failure: return .unavailable
        }

        let normalizedExpectedHost = lifecycle.expectedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedExpectedHost == "tailscale" || normalizedExpectedHost == "127.0.0.1" else {
            return .unavailable
        }
        let transportHost: String
        if normalizedExpectedHost == "tailscale" {
            guard let resolved = validatedTailscaleHost(await resolveTailscale()) else { return .unavailable }
            transportHost = resolved
        } else {
            transportHost = "127.0.0.1"
        }
        guard !transportHost.isEmpty else { return .unavailable }

        let pingResult: ServerPingResult
        do {
            pingResult = try await ping(transportHost, lifecycle.expectedPort, token)
        } catch is CancellationError {
            return .unavailable
        } catch {
            return .unavailable
        }
        let info: ServerPingInfo
        switch pingResult {
        case .success(let value): info = value
        case .unauthorized: return .unauthorized
        case .unreachable, .timeout, .malformedResponse: return .unavailable
        }

        async let supervisorStart = ServerProcessProbe.processStartIdentity(pid: lifecycle.supervisorPid)
        async let childStart = ServerProcessProbe.processStartIdentity(pid: lifecycle.childPid)
        async let command = ServerProcessProbe.processCommand(pid: lifecycle.childPid)
        async let uptime = ServerProcessProbe.processElapsedTime(pid: lifecycle.childPid)
        async let listeners = ServerProcessProbe.listenerPIDs(port: lifecycle.expectedPort)
        guard validates(
            lifecycle: lifecycle,
            selected: selected,
            info: info,
            observedSupervisorStartIdentity: await supervisorStart,
            observedChildStartIdentity: await childStart,
            listenerPIDs: await listeners,
            processCommand: await command
        ) else { return .unavailable }

        return .admitted(Admission(
            lifecycle: lifecycle,
            processID: lifecycle.childPid,
            uptime: await uptime,
            transportHost: transportHost,
            pairingTransportAvailable: isPairingHost(transportHost),
            selectedPayload: selected,
            info: info
        ))
    }

    static func validates(
        lifecycle: Lifecycle,
        selected: GatewayPayloadValidationResult,
        info: ServerPingInfo,
        observedSupervisorStartIdentity: String?,
        observedChildStartIdentity: String?,
        listenerPIDs: Set<Int>,
        processCommand: String?
    ) -> Bool {
        guard lifecycle.lifecycle == "ready",
              lifecycle.expectedPort == TronGatewayProfile.debug.port,
              lifecycle.supervisorPid > 0,
              lifecycle.childPid > 0,
              lifecycle.supervisorPid != lifecycle.childPid,
              observedSupervisorStartIdentity == lifecycle.supervisorStartIdentity,
              observedChildStartIdentity == lifecycle.childStartIdentity,
              listenerPIDs == Set([lifecycle.childPid]),
              let sourceRevision = selected.manifest.sourceRevision,
              let runtimeEpoch = selected.manifest.runtimeEpoch,
              selected.manifest.channel == TronGatewayProfile.debug.channel,
              lifecycle.epoch == runtimeEpoch,
              lifecycle.sourceRevision == sourceRevision,
              lifecycle.buildFingerprint == selected.manifest.payloadFingerprint,
              StableGatewayObserver.authenticatedIdentity(
                info,
                matches: selected.manifest,
                channel: TronGatewayProfile.debug.channel
              ),
              StableGatewayObserver.processCommand(
                processCommand,
                owns: selected.root,
                expectedHost: lifecycle.expectedHost,
                profile: TronGatewayProfile.debug
              ) else {
            return false
        }
        return true
    }

    static func validatedTailscaleHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return TailscaleProbe.isTailscaleAddress(normalized) ? normalized : nil
    }

    static func isPairingHost(_ host: String) -> Bool {
        validatedTailscaleHost(host) != nil
    }

    private static func lifecycle(home: URL, fileManager: FileManager) -> Lifecycle? {
        let url = lifecycleURL(home: home)
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == getuid(),
              (value.st_mode & 0o022) == 0,
              value.st_size > 0,
              value.st_size <= maximumLifecycleBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let lifecycle = try? JSONDecoder().decode(Lifecycle.self, from: data),
              GatewayPayloadStore.validComponent(
                lifecycle.epoch,
                maximumLength: GatewayPayloadStore.versionComponentLimit
              ),
              !lifecycle.supervisorStartIdentity.isEmpty,
              !lifecycle.childStartIdentity.isEmpty,
              !lifecycle.sourceRevision.isEmpty,
              lifecycle.sourceRevision.utf8.count <= 256,
              lifecycle.buildFingerprint.count == 64,
              lifecycle.buildFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return lifecycle
    }
}
