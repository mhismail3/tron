import Foundation
import ServiceManagement

/// Live `LaunchAgentManaging` implementation. Registration goes through
/// `SMAppService`; `launchctl` is used only for diagnostics and explicit
/// restart/kickstart.
struct LiveLaunchAgentManager: LaunchAgentManaging {
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome {
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return .binaryMissing(path: plistPath.path)
        }
        guard FileManager.default.fileExists(atPath: TronPaths.serverHelperBinary.path) else {
            return .binaryMissing(path: TronPaths.serverHelperBinary.path)
        }

        let service = SMAppService.agent(plistName: "\(label).plist")
        let status = ExistingInstallDetector.serviceStatus(label: label)
        let currentVariant = MacRuntimeVariant.detect()
        let runtime = await runtimeInfo(label: label)
        let runningParent = runtime?.parentBundleIdentifier
        let shouldReplaceStaleRuntime = Self.runtimeRequiresReplacement(
            runtimeInfo: runtime,
            expectedHelperPath: TronPaths.serverHelperBinary.path
        )
        let shouldTakeOverRuntime = Self.shouldBootoutForTakeover(
            status: status,
            currentVariant: currentVariant,
            runningParentBundleIdentifier: runningParent,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        )
        let shouldRefreshCurrentRegistration = Self.shouldRefreshRegistrationForCurrentBundle(
            status: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            currentParentBundleVersion: Self.currentParentBundleVersion(),
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        ) || Self.shouldRefreshRegistrationForLaunchConstraints(
            status: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        ) || Self.shouldRefreshRegistrationForGatewaySupervision(
            status: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            expectedMarker: TronPaths.gatewaySupervisionValue,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent
        )

        if let outcome = Self.preRegistrationOutcome(
            for: status,
            currentVariant: currentVariant,
            runtimeInfo: runtime,
            runningParentBundleIdentifier: runningParent,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent,
            expectedHelperPath: TronPaths.serverHelperBinary.path,
            shouldRefreshCurrentRegistration: shouldRefreshCurrentRegistration
        ) {
            return outcome
        }
        if shouldReplaceStaleRuntime || shouldTakeOverRuntime || shouldRefreshCurrentRegistration {
            let bootout = await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", "gui/\(currentUID())/\(label)"]
            )
            guard bootout.exitCode == 0 else {
                return .launchdRefused(
                    message: bootout.stderr.isEmpty
                        ? "Tron Agent could not unload the stale LaunchAgent before re-registering it."
                        : bootout.stderr
                )
            }
        }
        let externalPortBound = await isPortBound(TronPaths.defaultServerPort)
        if Self.shouldRefuseExternalServer(
            status: status,
            runningParentBundleIdentifier: runningParent,
            portBound: externalPortBound
        ) {
            return .launchdRefused(message: "Another Tron is already running on port \(TronPaths.defaultServerPort). Stop it before installing Tron Agent.")
        }

        if Self.shouldUnregisterBeforeRegister(
            status: status,
            runningParentBundleIdentifier: runningParent,
            shouldReplaceStaleRuntime: shouldReplaceStaleRuntime,
            shouldTakeOverRuntime: shouldTakeOverRuntime,
            shouldRefreshCurrentRegistration: shouldRefreshCurrentRegistration
        ) {
            do {
                try await service.unregister()
            } catch {
                return .launchdRefused(
                    message: "Tron Agent is registered but launchd has no loaded job, and macOS refused to replace the registration: \(error.localizedDescription)"
                )
            }
        }

        do {
            try service.register()
        } catch {
            return .launchdRefused(message: error.localizedDescription)
        }

        switch service.status {
        case .enabled:
            return .ok
        case .requiresApproval:
            return .requiresApproval(message: "Approve Tron Agent in Login Items to finish installation.")
        case .notFound:
            return .unknown(message: "ServiceManagement could not find the bundled Tron Agent LaunchAgent after registration.")
        case .notRegistered:
            return .unknown(message: "Tron Agent was not registered.")
        @unknown default:
            return .unknown(message: "Tron Agent registration returned an unknown status.")
        }
    }

    static func preRegistrationOutcome(
        for status: ExistingInstallDetector.ServiceRegistrationStatus,
        currentVariant: MacRuntimeVariant = MacRuntimeVariant.detect(),
        runtimeInfo: LaunchAgentRuntimeInfo? = nil,
        runningParentBundleIdentifier: String? = nil,
        canManageLaunchAgent: Bool = true,
        expectedHelperPath: String = TronPaths.serverHelperBinary.path,
        shouldRefreshCurrentRegistration: Bool = false
    ) -> LaunchAgentOutcome? {
        switch status {
        case .requiresApproval:
            return .requiresApproval(message: "Approve Tron Agent in Login Items to finish installation.")
        case .enabled, .notRegistered, .notFound, .unknown:
            let runtimeIsStale = runtimeRequiresReplacement(runtimeInfo: runtimeInfo, expectedHelperPath: expectedHelperPath)
            let resolvedParent = runtimeInfo?.parentBundleIdentifier ?? runningParentBundleIdentifier

            if !canManageLaunchAgent {
                if runtimeIsStale || resolvedParent == nil {
                    return .launchdRefused(
                        message: "This Xcode Debug wrapper is in companion mode and cannot install or repair the production Tron Agent. Use /Applications/Tron.app, or run the isolated install-testing scheme."
                    )
                }
                return .alreadyLoaded
            }

            if runtimeIsStale {
                return nil
            }

            guard let resolvedParent else {
                // SMAppService can report an enabled Login Item even when
                // launchd has no loaded job for the label, e.g. a stale
                // DerivedData Debug registration. Route through registration
                // so the current app bundle remains the source of truth.
                return nil
            }

            if resolvedParent == currentVariant.expectedParentBundleIdentifier {
                if shouldRefreshCurrentRegistration {
                    return nil
                }
                return .alreadyLoaded
            }
            if currentVariant.canTakeOverRegistration(ownedBy: resolvedParent) {
                return nil
            }
            return .launchdRefused(
                message: "Tron Agent is currently managed by \(resolvedParent). Stop that build before installing this one."
            )
        }
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

    static func shouldUnregisterBeforeRegister(
        status: ExistingInstallDetector.ServiceRegistrationStatus,
        runningParentBundleIdentifier: String?,
        shouldReplaceStaleRuntime: Bool,
        shouldTakeOverRuntime: Bool,
        shouldRefreshCurrentRegistration: Bool
    ) -> Bool {
        status == .enabled
            && (runningParentBundleIdentifier == nil
                || shouldReplaceStaleRuntime
                || shouldTakeOverRuntime
                || shouldRefreshCurrentRegistration)
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

    static func runtimeRequiresReplacement(
        runtimeInfo: LaunchAgentRuntimeInfo?,
        expectedHelperPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let runtimeInfo,
              let executablePath = runtimeInfo.executablePath,
              !executablePath.isEmpty else {
            return false
        }

        let expected = URL(fileURLWithPath: expectedHelperPath).standardizedFileURL.path
        let actual = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        return actual != expected || !fileExists(actual)
    }

    func unload(label: String) async -> LaunchAgentOutcome {
        let service = SMAppService.agent(plistName: "\(label).plist")
        if let outcome = Self.preUnregistrationOutcome(for: ExistingInstallDetector.serviceStatus(label: label)) {
            return outcome
        }
        do {
            try await service.unregister()
            return .ok
        } catch {
            return .unknown(message: error.localizedDescription)
        }
    }

    static func preUnregistrationOutcome(
        for status: ExistingInstallDetector.ServiceRegistrationStatus
    ) -> LaunchAgentOutcome? {
        switch status {
        case .notRegistered:
            return .ok
        case .notFound:
            return .binaryMissing(path: TronPaths.launchAgentPlistPath.path)
        case .enabled, .requiresApproval, .unknown:
            return nil
        }
    }

    func restart(label: String) async -> LaunchAgentOutcome {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["kickstart", "-k", "gui/\(currentUID())/\(label)"]
        )
        return result.exitCode == 0
            ? .ok
            : .launchdRefused(message: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    func isLoaded(label: String) async -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(label)"]
        )
        return result.exitCode == 0
    }

    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo? {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", "gui/\(currentUID())/\(label)"]
        )
        guard result.exitCode == 0 else { return nil }
        let pid = parsePID(from: result.stdout)
        let uptime: String?
        if let pid {
            uptime = await ServerProcessProbe.processElapsedTime(pid: pid)
        } else {
            uptime = nil
        }
        return LaunchAgentRuntimeInfo(
            pid: pid,
            uptime: uptime,
            parentBundleIdentifier: parseLaunchctlValue(
                named: "parent bundle identifier",
                from: result.stdout
            ),
            parentBundleVersion: parseLaunchctlValue(named: "parent bundle version", from: result.stdout),
            executablePath: parseLaunchctlDictionaryValue(named: "Executable", from: result.stdout),
            gatewaySupervisionMarker: parseLaunchctlEnvironmentValue(
                named: TronPaths.gatewaySupervisionEnv,
                from: result.stdout
            ),
            needsLaunchConstraintRefresh: result.stdout.contains("needs LWCR update")
        )
    }

    private func parsePID(from launchctlOutput: String) -> Int? {
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid =") else { continue }
            let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private func parseLaunchctlValue(named key: String, from launchctlOutput: String) -> String? {
        let prefix = "\(key) ="
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func parseLaunchctlEnvironmentValue(named key: String, from launchctlOutput: String) -> String? {
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            for separator in [" => ", " = "] {
                let prefix = "\(key)\(separator)"
                guard text.hasPrefix(prefix) else { continue }
                let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func parseLaunchctlDictionaryValue(named key: String, from launchctlOutput: String) -> String? {
        let prefix = "\"\(key)\" => \""
        for line in launchctlOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let range = text.range(of: prefix) else { continue }
            let remainder = text[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { continue }
            let value = String(remainder[..<end])
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func isPortBound(_ port: Int) async -> Bool {
        let result = await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        )
        return result.exitCode == 0 && !result.stdout.isEmpty
    }

    private func currentUID() -> Int {
        Int(getuid())
    }
}
