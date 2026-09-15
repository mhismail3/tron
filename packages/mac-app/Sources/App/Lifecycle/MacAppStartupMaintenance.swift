import Foundation

struct MacAppVersionIdentity: Codable, Equatable, Sendable {
    var canonicalVersion: String
    var buildNumber: String
    var gatewayFingerprint: String?

    init(canonicalVersion: String, buildNumber: String, gatewayFingerprint: String? = nil) {
        self.canonicalVersion = canonicalVersion
        self.buildNumber = buildNumber
        self.gatewayFingerprint = gatewayFingerprint
    }

    static func current(bundle: Bundle = .main) -> MacAppVersionIdentity {
        let canonical = bundle.object(forInfoDictionaryKey: "TRONCanonicalVersion") as? String
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return MacAppVersionIdentity(
            canonicalVersion: canonical ?? marketing ?? "unknown",
            buildNumber: build ?? "unknown",
            gatewayFingerprint: gatewayFingerprint(bundle: bundle)
        )
    }

    private static func gatewayFingerprint(bundle: Bundle) -> String? {
        let manifest = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/Gateway/manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fingerprint = object["payloadFingerprint"] as? String,
              !fingerprint.isEmpty else { return nil }
        return fingerprint
    }
}

enum MacAppVersionMarkerStore {
    static func read(at path: URL) -> MacAppVersionIdentity? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(MacAppVersionIdentity.self, from: data)
    }

    static func write(_ version: MacAppVersionIdentity, at path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(version)
        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
    }
}

enum MacAppStartupContext: Equatable, Sendable {
    case existingOnboardedLaunch
    case wizardCompletion
}

enum MacAppStartupSkipReason: Equatable, Sendable {
    case notOnboarded
    case unmanagedWrapper
    case versionAlreadyRecorded
}

enum MacAppStartupMaintenanceResult: Equatable, Sendable {
    case restarted(LaunchAgentOutcome)
    case restartUnhealthy(LaunchAgentOutcome, ServerPingResult)
    case recordedCurrentVersion
    case needsAttention(String)
    case skipped(MacAppStartupSkipReason)
}

enum MacAppStartupMaintenance {
    static func run(
        setup: EnvironmentSetup,
        controller: MenuBarController?,
        context: MacAppStartupContext
    ) async -> MacAppStartupMaintenanceResult {
        let currentVersion = setup.currentAppVersion()
        let startupMode = setup.resolvedStartupMode(
            command: .normal,
            underTests: false,
            onboardedOverride: context == .wizardCompletion ? false : nil
        )
        let canManage = startupMode == .onboarded
            || (context == .wizardCompletion && startupMode == .wizard)
        if context == .wizardCompletion, canManage {
            recordCurrentVersion(currentVersion, setup: setup)
            return .recordedCurrentVersion
        }

        let recordedVersion = setup.readRecordedAppVersion()
        let onboarded: Bool
        switch startupMode {
        case .onboarded: onboarded = true
        case .wizard: onboarded = false
        default: onboarded = false
        }
        let skip = restartSkipReason(currentVersion: currentVersion, recordedVersion: recordedVersion,
                                     canManageLaunchAgent: canManage, onboarded: onboarded)
        if let skip, skip != .versionAlreadyRecorded { return .skipped(skip) }
        guard let loaded = await setup.launchAgentManager.isLoaded(label: setup.launchAgentLabel) else {
            return .needsAttention("Could not inspect Gateway registration. No service change was made.")
        }
        let runtime = await setup.launchAgentManager.runtimeInfo(label: setup.launchAgentLabel)
        if loaded, runtime?.pid != nil {
            let ownershipHealthy = await setup.runtimeOwnershipHealthy()
            let registrationNeedsRepair = LiveLaunchAgentManager.shouldRefreshRegistrationForCurrentBundle(
                status: .enabled, currentVariant: setup.runtimeVariant, runtimeInfo: runtime,
                currentParentBundleVersion: currentVersion.buildNumber, canManageLaunchAgent: canManage)
                || runtime?.needsLaunchConstraintRefresh == true || runtime?.gatewayExitPolicy != "stop-on-success"
            let health = await ServerHealthAwaiter.waitForHealthy(token: setup.readBearerToken(),
                expectedChannel: setup.profile.channel, attempts: 1, delayNanoseconds: 0, pingServer: setup.pingServer)
            if case .success = health, ownershipHealthy, !registrationNeedsRepair {
                // Opening a wrapper must not restart healthy accepted work just
                // because its build marker changed. Quit owns graceful retirement.
                recordCurrentVersion(currentVersion, setup: setup)
                return skip == .versionAlreadyRecorded ? .skipped(.versionAlreadyRecorded) : .recordedCurrentVersion
            }
            let message = "A Gateway is already running but its ownership, health or registration needs attention. Use a verified graceful Restart or finish the Mac update; startup did not replace it."
            await MainActor.run { controller?.applySnapshot(.init(state: .failed(reason: message))) }
            return .needsAttention(message)
        }
        if loaded && runtime == nil { return .needsAttention("Gateway process observation failed. No service change was made.") }

        await MainActor.run {
            controller?.applySnapshot(ServerStatusSnapshot(
                state: .busy(.starting),
                tailscaleIP: setup.readTailscaleIPFromSettings()
            ))
        }

        let outcome = await LaunchAgentLoader.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        let health: ServerPingResult?
        switch outcome {
        case .ok, .alreadyLoaded:
            health = await ServerHealthAwaiter.waitForHealthy(setup: setup)
        case .requiresApproval, .launchdRefused, .binaryMissing, .unknown:
            health = nil
        }
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        await MainActor.run {
            controller?.applySnapshot(snapshot)
        }
        switch outcome {
        case .ok, .alreadyLoaded:
            if let health, case .success = health {
                recordCurrentVersion(currentVersion, setup: setup)
            } else {
                return .restartUnhealthy(outcome, health ?? .unreachable)
            }
        case .requiresApproval, .launchdRefused, .binaryMissing, .unknown:
            break
        }
        return .restarted(outcome)
    }

    private static func restartSkipReason(
        currentVersion: MacAppVersionIdentity,
        recordedVersion: MacAppVersionIdentity?,
        canManageLaunchAgent: Bool,
        onboarded: Bool
    ) -> MacAppStartupSkipReason? {
        if !onboarded { return .notOnboarded }
        if !canManageLaunchAgent { return .unmanagedWrapper }
        if recordedVersion == currentVersion { return .versionAlreadyRecorded }
        return nil
    }

    @discardableResult
    static func recordCurrentVersion(setup: EnvironmentSetup) -> Bool {
        recordCurrentVersion(setup.currentAppVersion(), setup: setup)
    }

    @discardableResult
    private static func recordCurrentVersion(_ version: MacAppVersionIdentity, setup: EnvironmentSetup) -> Bool {
        do {
            try setup.writeRecordedAppVersion(version)
            return true
        } catch {
            NSLog("[Tron] Failed to record Mac app version marker: %@", error.localizedDescription)
            return false
        }
    }
}
