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
    case skipped(MacAppStartupSkipReason)
}

enum MacAppStartupMaintenance {
    static func run(
        setup: EnvironmentSetup,
        controller: MenuBarController?,
        context: MacAppStartupContext
    ) async -> MacAppStartupMaintenanceResult {
        let currentVersion = setup.currentAppVersion()
        if context == .wizardCompletion,
           setup.canManageLaunchAgent {
            recordCurrentVersion(currentVersion, setup: setup)
            return .recordedCurrentVersion
        }

        let recordedVersion = setup.readRecordedAppVersion()
        let onboarded = setup.onboardedSentinelExists()
        if let reason = restartSkipReason(
            currentVersion: currentVersion,
            recordedVersion: recordedVersion,
            canManageLaunchAgent: setup.canManageLaunchAgent,
            onboarded: onboarded
        ) {
            guard reason == .versionAlreadyRecorded else { return .skipped(reason) }
            let runtime = await setup.launchAgentManager.runtimeInfo(label: setup.launchAgentLabel)
            let currentVariant = MacRuntimeVariant.detect()
            let expectedHelperPath = setup.applicationBundle
                .appendingPathComponent("Contents/Library/LoginItems/\(setup.profile.agentBundleName).app/Contents/MacOS/tron")
                .path
            let registrationNeedsRepair = runtime == nil
                || runtime?.parentBundleIdentifier != currentVariant.expectedParentBundleIdentifier
                || runtime?.gatewaySupervisionMarker != TronPaths.gatewaySupervisionValue
                || runtime?.gatewayChannelMarker != setup.profile.channel
                || LiveLaunchAgentManager.runtimeRequiresReplacement(
                    runtimeInfo: runtime,
                    profile: setup.profile,
                    expectedHelperPath: expectedHelperPath
                )
                || LiveLaunchAgentManager.shouldRefreshRegistrationForCurrentBundle(
                    status: .enabled,
                    currentVariant: currentVariant,
                    runtimeInfo: runtime,
                    currentParentBundleVersion: currentVersion.buildNumber,
                    canManageLaunchAgent: setup.canManageLaunchAgent
                )
                || runtime?.needsLaunchConstraintRefresh == true
            let health = await ServerHealthAwaiter.waitForHealthy(
                token: setup.readBearerToken(),
                expectedChannel: setup.profile.channel,
                attempts: 1,
                delayNanoseconds: 0,
                pingServer: setup.pingServer
            )
            if case .success = health, !registrationNeedsRepair { return .skipped(reason) }
            // A same-version wrapper launch still repairs a stale, unsupervised,
            // or unhealthy LaunchAgent; the version marker is not a health assertion.
        }

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
