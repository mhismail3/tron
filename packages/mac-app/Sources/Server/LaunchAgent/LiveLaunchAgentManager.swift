import Foundation
import ServiceManagement

/// Live `LaunchAgentManaging` implementation. Registration goes through
/// `SMAppService`; `launchctl` is used only for diagnostics and explicit
/// restart/kickstart.
struct LiveLaunchAgentManager: LaunchAgentManaging {
    let profile: TronGatewayProfile

    init(profile: TronGatewayProfile = .stable) {
        self.profile = profile
    }

    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome {
        guard profile == .stable else {
            return .launchdRefused(message: "Debug Gateway lifecycle belongs to scripts/tron dev.")
        }
        guard label == profile.launchAgentLabel,
              plistPath.standardizedFileURL.path == TronPaths.launchAgentPlistPath(profile: profile).standardizedFileURL.path else {
            return .launchdRefused(message: "LaunchAgent profile arguments do not match the requested Gateway profile.")
        }
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return .binaryMissing(path: plistPath.path)
        }
        let helperBinary = TronPaths.serverHelperBinary(profile: profile)
        guard FileManager.default.fileExists(atPath: helperBinary.path) else {
            return .binaryMissing(path: helperBinary.path)
        }
        guard ExistingInstallDetector.launchAgentPlistIsCurrent(profile: profile, plistPath: plistPath) else {
            return .launchdRefused(message: "The bundled LaunchAgent plist does not match the requested Gateway profile.")
        }
        if let signatureProblem = await ExistingInstallDetector.bundleSignatureProblem(
            of: TronPaths.serverHelperBundle(profile: profile),
            expectedBundleIdentifier: profile.launchAgentLabel
        ) {
            return .launchdRefused(message: signatureProblem)
        }

        let currentVariant = MacRuntimeVariant.detect()
        let service = SMAppService.agent(plistName: "\(label).plist")
        let status = ExistingInstallDetector.serviceStatus(label: label)
        let runtime: LaunchAgentRuntimeInfo?
        do { runtime = try await LaunchAgentRuntimeReader.read(label: label) } catch {
            return .unknown(message: "Could not inspect the LaunchAgent. No registration changes were made.")
        }
        let runningParent = runtime?.parentBundleIdentifier
        let plan = Self.registrationPlan(
            status: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent(profile: profile),
            profile: profile,
            expectedHelperPath: helperBinary.path,
            currentParentBundleVersion: Self.currentParentBundleVersion()
        )
        switch plan {
        case .keep:
            return .alreadyLoaded
        case .refuse(let message):
            return .launchdRefused(message: message)
        case .change:
            break
        }

        let externalPortBound: Bool
        do { externalPortBound = try await isPortBound(profile.port) } catch {
            return .unknown(message: "Could not verify port ownership. No registration changes were made.")
        }
        if Self.shouldRefuseExternalServer(status: status, runningParentBundleIdentifier: runningParent, portBound: externalPortBound) {
            return .launchdRefused(message: "Another Tron is already running on port \(profile.port). Stop it before installing this Gateway profile.")
        }
        if let failure = await Self.execute(plan.steps, perform: { step in
            switch step {
            case .bootout:
                let bootout = await Subprocess.run(
                    executable: URL(fileURLWithPath: "/bin/launchctl"),
                    arguments: ["bootout", "gui/\(currentUID())/\(label)"],
                    policy: .acceptedOperation
                )
                guard bootout.exitCode >= 0 else {
                    return .unknown(message: "Could not confirm the unload command outcome. Inspect Gateway state before retrying.")
                }
                guard bootout.exitCode == 0 else {
                    return .launchdRefused(message: bootout.stderr.isEmpty
                        ? "Tron Agent could not unload the stale LaunchAgent before re-registering it."
                        : bootout.stderr)
                }
            case .unregister:
                do {
                    try await service.unregister()
                    TronLog.shared.record(.info, event: "launch-agent.unregister", source: "launch-agent", message: "LaunchAgent unregistered for replacement", outcome: "success")
                } catch {
                    TronLog.shared.record(.error, event: "launch-agent.unregister", source: "launch-agent", message: "LaunchAgent unregister failed: \(error.localizedDescription)", outcome: "failed")
                    return .launchdRefused(message: "Tron Agent registration could not be replaced: \(error.localizedDescription)")
                }
            case .register:
                do {
                    try service.register()
                    TronLog.shared.record(.info, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent registration requested", outcome: "success")
                } catch {
                    TronLog.shared.record(.error, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent registration failed: \(error.localizedDescription)", outcome: "failed")
                    return .launchdRefused(message: error.localizedDescription)
                }
            }
            return nil
        }) {
            return failure
        }

        switch service.status {
        case .enabled:
            TronLog.shared.record(.info, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent is enabled", outcome: "success")
            return .ok
        case .requiresApproval:
            TronLog.shared.record(.warning, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent registration needs user approval", outcome: "requires-approval")
            return .requiresApproval(message: "Approve Tron Agent in Login Items to finish installation.")
        case .notFound:
            TronLog.shared.record(.error, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent missing after registration", outcome: "missing")
            return .unknown(message: "ServiceManagement could not find the bundled Tron Agent LaunchAgent after registration.")
        case .notRegistered:
            TronLog.shared.record(.error, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent is not registered after registration", outcome: "not-registered")
            return .unknown(message: "Tron Agent was not registered.")
        @unknown default:
            TronLog.shared.record(.error, event: "launch-agent.register", source: "launch-agent", message: "LaunchAgent registration returned an unknown status", outcome: "unknown")
            return .unknown(message: "Tron Agent registration returned an unknown status.")
        }
    }

    static func registrationPlan(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runtimeInfo: LaunchAgentRuntimeInfo?,
        canManageLaunchAgent: Bool,
        profile: TronGatewayProfile = .stable,
        expectedHelperPath: String,
        currentParentBundleVersion: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> LaunchAgentRegistrationPlan {
        if status == .requiresApproval {
            return .refuse(message: "Approve Tron Agent in Login Items to finish installation.")
        }
        // Missing observation is not evidence of a stale running process.
        // In particular, a cancelled/timed-out ps must never authorize bootout.
        if runtimeInfo?.pid != nil, runtimeInfo?.processCommand?.isEmpty != false {
            return .refuse(message: "Could not verify the running Gateway command. No registration changes were made.")
        }
        let parent = runtimeInfo?.parentBundleIdentifier
        let stale = runtimeRequiresReplacement(
            runtimeInfo: runtimeInfo, profile: profile, expectedHelperPath: expectedHelperPath,
            fileExists: fileExists
        )
        let takeover = shouldBootoutForTakeover(
            status: status, currentVariant: currentVariant,
            runningParentBundleIdentifier: parent, canManageLaunchAgent: canManageLaunchAgent
        )
        let refresh = shouldRefreshRegistrationForCurrentBundle(
            status: status, currentVariant: currentVariant, runtimeInfo: runtimeInfo,
            currentParentBundleVersion: currentParentBundleVersion, canManageLaunchAgent: canManageLaunchAgent
        ) || shouldRefreshRegistrationForLaunchConstraints(
            status: status, currentVariant: currentVariant, runtimeInfo: runtimeInfo,
            canManageLaunchAgent: canManageLaunchAgent
        ) || shouldRefreshRegistrationForGatewaySupervision(
            status: status, currentVariant: currentVariant, runtimeInfo: runtimeInfo,
            canManageLaunchAgent: canManageLaunchAgent
        )
        guard canManageLaunchAgent else {
            if stale || parent == nil {
                return .refuse(message: "This Xcode Debug wrapper is a read-only companion. Use /Applications/Tron.app to manage Stable.")
            }
            return .keep
        }
        let registrationExists: Bool
        switch status {
        case .enabled, .unknown: registrationExists = true
        case .requiresApproval, .notRegistered, .notFound: registrationExists = false
        }
        let repair = stale || takeover || refresh
        var steps: [LaunchAgentRegistrationPlan.Step] = []
        if repair { steps.append(.bootout) }
        if registrationExists && (parent == nil || repair) { steps.append(.unregister) }
        if repair { return .change(steps: steps + [.register]) }
        guard let parent else { return .change(steps: steps + [.register]) }
        if parent == currentVariant.expectedParentBundleIdentifier { return .keep }
        return .refuse(message: "Tron Agent is currently managed by \(parent). Stop that build before installing this one.")
    }

    /// Executes the already-resolved plan without re-reading launchd state.
    /// This is the live load path's only step loop. Stop on the first reported
    /// failure; do not add retries or caller-cancellation checks between accepted steps.
    static func execute(
        _ steps: [LaunchAgentRegistrationPlan.Step],
        perform: (LaunchAgentRegistrationPlan.Step) async -> LaunchAgentOutcome?
    ) async -> LaunchAgentOutcome? {
        for step in steps {
            if let outcome = await perform(step) { return outcome }
        }
        return nil
    }

    static func shouldBootoutForTakeover(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runningParentBundleIdentifier: String?,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status != .requiresApproval,
              let runningParentBundleIdentifier,
              runningParentBundleIdentifier != currentVariant.expectedParentBundleIdentifier else {
            return false
        }
        return currentVariant.canTakeOverRegistration(ownedBy: runningParentBundleIdentifier)
    }

    static func shouldRefuseExternalServer(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        runningParentBundleIdentifier: String?,
        portBound: Bool
    ) -> Bool {
        guard status != .enabled,
              status != .requiresApproval,
              runningParentBundleIdentifier == nil else {
            return false
        }
        return portBound
    }

    static func shouldRefreshRegistrationForCurrentBundle(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runtimeInfo: LaunchAgentRuntimeInfo?,
        currentParentBundleVersion: String?,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status == .enabled,
              let runtimeInfo,
              runtimeInfo.parentBundleIdentifier == currentVariant.expectedParentBundleIdentifier,
              let registeredVersion = runtimeInfo.parentBundleVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !registeredVersion.isEmpty,
              let currentParentBundleVersion = currentParentBundleVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentParentBundleVersion.isEmpty else {
            return false
        }
        return registeredVersion != currentParentBundleVersion
    }

    static func shouldRefreshRegistrationForGatewaySupervision(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runtimeInfo: LaunchAgentRuntimeInfo?,
        expectedMarker: String = TronPaths.gatewaySupervisionValue,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status == .enabled,
              let runtimeInfo,
              runtimeInfo.parentBundleIdentifier == currentVariant.expectedParentBundleIdentifier else {
            return false
        }
        return runtimeInfo.gatewaySupervisionMarker != expectedMarker
    }

    static func shouldRefreshRegistrationForLaunchConstraints(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant,
        runtimeInfo: LaunchAgentRuntimeInfo?,
        canManageLaunchAgent: Bool = true
    ) -> Bool {
        guard canManageLaunchAgent,
              status == .enabled,
              let runtimeInfo,
              runtimeInfo.parentBundleIdentifier == currentVariant.expectedParentBundleIdentifier else {
            return false
        }
        return runtimeInfo.needsLaunchConstraintRefresh
    }

    static func currentParentBundleVersion(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static func runtimeOwnsProfile(
        runtimeInfo: LaunchAgentRuntimeInfo?,
        profile: TronGatewayProfile,
        expectedParentBundleIdentifier: String?,
        expectedHelperPath: String,
        expectedSupervisionMarker: String = TronPaths.gatewaySupervisionValue,
        expectedPayloadRoot: URL? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let runtimeInfo,
              runtimeInfo.pid != nil,
              runtimeInfo.parentBundleIdentifier == expectedParentBundleIdentifier,
              runtimeInfo.gatewaySupervisionMarker == expectedSupervisionMarker,
              runtimeInfo.gatewayChannelMarker == profile.channel else { return false }
        return !runtimeRequiresReplacement(
            runtimeInfo: runtimeInfo,
            profile: profile,
            expectedHelperPath: expectedHelperPath,
            expectedPayloadRoot: expectedPayloadRoot,
            fileExists: fileExists
        )
    }

    static func runtimeRequiresReplacement(
        runtimeInfo: LaunchAgentRuntimeInfo?,
        profile: TronGatewayProfile = .stable,
        expectedHelperPath: String,
        expectedPayloadRoot: URL? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let runtimeInfo else { return false }
        guard runtimeInfo.gatewaySupervisionMarker == TronPaths.gatewaySupervisionValue,
              runtimeInfo.gatewayChannelMarker == profile.channel else { return true }

        let expected = URL(fileURLWithPath: expectedHelperPath).standardizedFileURL.path
        guard fileExists(expected), processCommandOwnsProfile(
            runtimeInfo.processCommand,
            profile: profile,
            expectedHelperPath: expectedHelperPath,
            expectedPayloadRoot: expectedPayloadRoot
        ) else { return true }
        if let executablePath = runtimeInfo.executablePath, !executablePath.isEmpty {
            let actual = URL(fileURLWithPath: executablePath).standardizedFileURL.path
            return actual != expected
        }

        guard let bundleProgram = runtimeInfo.bundleProgram,
              !bundleProgram.isEmpty,
              let contentsRange = expected.range(of: "Contents/") else {
            return true
        }
        return bundleProgram != String(expected[contentsRange.lowerBound...])
    }

    static func processCommandOwnsProfile(
        _ command: String?,
        profile: TronGatewayProfile,
        expectedHelperPath: String,
        expectedPayloadRoot: URL? = nil
    ) -> Bool {
        guard let command, !command.isEmpty else { return false }
        let fields = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 6,
              let runtimeRange = fields[0].range(of: "/runtime/node-", options: .backwards) else {
            return false
        }
        let payloadRoot = String(fields[0][..<runtimeRange.lowerBound])
        if let expectedPayloadRoot,
           payloadRoot != expectedPayloadRoot.standardizedFileURL.path { return false }
        guard fields[0] == "\(payloadRoot)/runtime/node-arm64"
                || fields[0] == "\(payloadRoot)/runtime/node-x64",
              fields[1] == "\(payloadRoot)/app/dist/index.js",
              fields[2] == "--host", fields[3] == "tailscale",
              fields[4] == "--port", fields[5] == String(profile.port) else { return false }

        let helper = URL(fileURLWithPath: expectedHelperPath).standardizedFileURL.path
        guard let contentsRange = helper.range(of: "/Contents/Library/LoginItems/") else { return false }
        let bundledRoot = String(helper[..<contentsRange.lowerBound]) + "/Contents/Resources/Gateway"
        if payloadRoot == bundledRoot { return true }

        let versionsRoot = GatewayPayloadStore(
            home: TronPaths.tronHome(profile: profile),
            channel: profile.channel
        ).versionsRoot.standardizedFileURL.path
        let prefix = versionsRoot + "/"
        guard payloadRoot.hasPrefix(prefix) else { return false }
        let version = String(payloadRoot.dropFirst(prefix.count))
        return GatewayPayloadStore.validComponent(
            version,
            maximumLength: GatewayPayloadStore.versionComponentLimit
        )
    }

    func unload(label: String) async -> LaunchAgentOutcome {
        guard profile == .stable else {
            return .launchdRefused(message: "Debug Gateway lifecycle belongs to scripts/tron dev.")
        }
        guard label == profile.launchAgentLabel else {
            return .launchdRefused(message: "LaunchAgent label does not match the requested Gateway profile.")
        }
        let service = SMAppService.agent(plistName: "\(label).plist")
        if let outcome = Self.preUnregistrationOutcome(
            for: ExistingInstallDetector.serviceStatus(label: label), profile: profile
        ) {
            TronLog.shared.record(.info, event: "launch-agent.unregister", source: "launch-agent", message: "LaunchAgent already unregistered", outcome: "already-unregistered")
            return outcome
        }
        do {
            try await service.unregister()
            TronLog.shared.record(.info, event: "launch-agent.unregister", source: "launch-agent", message: "LaunchAgent unregistered", outcome: "success")
            return .ok
        } catch {
            TronLog.shared.record(.error, event: "launch-agent.unregister", source: "launch-agent", message: "LaunchAgent unregister failed: \(error.localizedDescription)", outcome: "failed")
            return .unknown(message: error.localizedDescription)
        }
    }

    static func preUnregistrationOutcome(
        for status: ExistingInstallDetector.ServiceRegistrationStatus,
        profile: TronGatewayProfile = .stable
    ) -> LaunchAgentOutcome? {
        switch status {
        case .notRegistered:
            return .ok
        case .notFound:
            return .binaryMissing(path: TronPaths.launchAgentPlistPath(profile: profile).path)
        case .enabled, .requiresApproval, .unknown:
            return nil
        }
    }

    func restart(label: String) async -> LaunchAgentOutcome {
        guard profile == .stable else {
            return .launchdRefused(message: "Debug Gateway lifecycle belongs to scripts/tron dev.")
        }
        guard label == profile.launchAgentLabel else {
            return .launchdRefused(message: "LaunchAgent label does not match the requested Gateway profile.")
        }
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["kickstart", "-k", "gui/\(currentUID())/\(label)"],
            policy: .acceptedOperation
        )
        guard result.exitCode >= 0 else {
            TronLog.shared.record(.error, event: "launch-agent.kickstart", source: "launch-agent", message: "Could not confirm kickstart outcome", outcome: "unknown")
            return .unknown(message: "Could not confirm the restart command outcome. Inspect Gateway state before retrying.")
        }
        let outcome = result.exitCode == 0 ? "success" : "failed"
        TronLog.shared.record(result.exitCode == 0 ? .info : .error, event: "launch-agent.kickstart", source: "launch-agent", message: "LaunchAgent kickstart completed", outcome: outcome)
        return result.exitCode == 0
            ? .ok
            : .launchdRefused(message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    func isLoaded(label: String) async -> Bool? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(label)"],
            policy: .observation
        )
        return try? Self.runtimeOutputAvailable(result)
    }

    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo? {
        try? await LaunchAgentRuntimeReader.read(label: label)
    }

    private func isPortBound(_ port: Int) async throws -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
            policy: .observation
        )
        return try Self.portBound(result)
    }

    enum ObservationFailure: Error { case unavailable }

    static func runtimeOutputAvailable(_ result: ProcessResult) throws -> Bool {
        // Negative status belongs to the capture owner (launch, cancellation,
        // timeout, limit or decode failure), not launchctl's not-loaded result.
        guard result.exitCode >= 0 else { throw ObservationFailure.unavailable }
        return result.exitCode == 0
    }

    static func portBound(_ result: ProcessResult) throws -> Bool {
        guard result.stderr.isEmpty else { throw ObservationFailure.unavailable }
        if result.exitCode == 0 { return !result.stdout.isEmpty }
        if result.exitCode == 1 && result.stdout.isEmpty { return false }
        throw ObservationFailure.unavailable
    }

    private func currentUID() -> Int {
        Int(getuid())
    }
}
