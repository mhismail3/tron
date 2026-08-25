import Foundation
import ServiceManagement

/// Decides whether the bundled `SMAppService` agent is registered and
/// the embedded helper is intact. Auth/settings/database files are user
/// data and are deliberately ignored.
enum ExistingInstallDetector {
    static func detect(
        helperBundle: URL = TronPaths.serverHelperBundle,
        helperBinary: URL = TronPaths.serverHelperBinary,
        plistPath: URL = TronPaths.launchAgentPlistPath,
        bundleVersionResolver: (URL) -> String? = ExistingInstallDetector.readMarketingVersion,
        bundleSignatureProblemResolver: (URL) -> String? = { ExistingInstallDetector.bundleSignatureProblem(of: $0) },
        gatewayPayloadProblemResolver: () -> String? = { nil },
        serviceStatusResolver: () -> ServiceRegistrationStatus = { ExistingInstallDetector.serviceStatus() }
    ) -> ExistingInstallStatus {
        let fm = FileManager.default
        let hasHelper = fm.fileExists(atPath: helperBundle.path)
        let hasBinary = fm.fileExists(atPath: helperBinary.path)
        let hasPlist = fm.fileExists(atPath: plistPath.path)
        let helperName = helperBundle.lastPathComponent

        guard hasHelper else {
            return hasPlist ? .partial(reason: "\(helperName) is missing from the application bundle") : .none
        }
        guard hasBinary else {
            return .partial(reason: "\(helperName) is missing its tron executable")
        }
        guard hasPlist else {
            return .partial(reason: "Bundled LaunchAgent plist is missing")
        }
        if let problem = bundleSignatureProblemResolver(helperBundle) {
            return .partial(reason: problem)
        }
        if let problem = gatewayPayloadProblemResolver() {
            return .partial(reason: problem)
        }

        switch serviceStatusResolver() {
        case .enabled:
            return .registered(version: bundleVersionResolver(helperBundle))
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .none
        case .notFound:
            return .partial(reason: "macOS cannot find the bundled Tron Agent Login Item")
        case .unknown(let message):
            return .partial(reason: message)
        }
    }

    enum ServiceRegistrationStatus: Equatable, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown(String)
    }

    static func serviceStatus(label: String = TronPaths.launchAgentLabel) -> ServiceRegistrationStatus {
        let service = SMAppService.agent(plistName: "\(label).plist")
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown("Tron Agent registration is in an unknown state")
        }
    }

    static func validateBundledHelper(
        helperBundle: URL = TronPaths.serverHelperBundle,
        helperBinary: URL = TronPaths.serverHelperBinary,
        plistPath: URL = TronPaths.launchAgentPlistPath,
        profile: TronGatewayProfile = .stable,
        signatureProblemResolver: ((URL) -> String?)? = nil
    ) -> String? {
        let fm = FileManager.default
        let helperName = helperBundle.lastPathComponent
        guard fm.fileExists(atPath: helperBundle.path) else {
            return "\(helperName) is missing from the application bundle."
        }
        guard fm.fileExists(atPath: helperBinary.path) else {
            return "\(helperName) is missing its tron executable."
        }
        guard fm.fileExists(atPath: plistPath.path) else {
            return "The bundled LaunchAgent plist is missing."
        }
        if let signatureProblemResolver {
            return signatureProblemResolver(helperBundle)
        }
        return bundleSignatureProblem(of: helperBundle, expectedBundleIdentifier: profile.launchAgentLabel)
    }

    static func validateGatewayPayload(
        payloadRoot: URL = TronPaths.gatewayPayloadRoot,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileSize: (String) -> Int64? = {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.int64Value
        },
        readData: (String) -> Data? = { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    ) -> String? {
        // The canonical validator owns complete bundled payload verification,
        // including the deterministic fingerprint and symlink boundary. Keep
        // the injectable checks below support focused validator fixtures.
        if case .failure(let error) = GatewayPayloadValidator.validate(payloadRoot: payloadRoot),
           payloadRoot.standardizedFileURL.path == TronPaths.gatewayPayloadRoot.standardizedFileURL.path {
            return "The bundled Gateway payload failed canonical validation: \(error)"
        }
        func usableFile(_ url: URL, minimumBytes: Int64 = 1) -> Bool {
            fileExists(url.path) && (fileSize(url.path) ?? 0) >= minimumBytes
        }

        let payloadManifest = payloadRoot.appendingPathComponent("manifest.json", isDirectory: false)
        guard usableFile(payloadManifest),
              (fileSize(payloadManifest.path) ?? Int64.max) <= Int64(GatewayPayloadStore.maxManifestBytes),
              let payloadManifestData = readData(payloadManifest.path),
              let identity = try? JSONDecoder().decode(GatewayPayloadManifest.self, from: payloadManifestData),
              identity.schema == GatewayPayloadStore.schema,
              identity.kind == GatewayPayloadManifest.payloadKind,
              GatewayPayloadStore.validComponent(identity.channel, maximumLength: GatewayPayloadStore.channelComponentLimit),
              GatewayPayloadStore.validComponent(identity.version, maximumLength: GatewayPayloadStore.versionComponentLimit),
              identity.payloadFingerprint.count == 64,
              identity.payloadFingerprint.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }),
              identity.sourceRevision?.isEmpty == false,
              identity.runtimeEpoch.map({ GatewayPayloadStore.validComponent($0, maximumLength: GatewayPayloadStore.versionComponentLimit) }) == true else {
            return "The bundled Gateway payload manifest is missing or invalid. Rebuild or reinstall Tron."
        }

        let entrypoint = payloadRoot.appendingPathComponent("app/dist/index.js", isDirectory: false)
        guard usableFile(entrypoint, minimumBytes: 1_024) else {
            return "The bundled Gateway entrypoint is missing or incomplete. Rebuild or reinstall Tron."
        }

        let packageManifest = payloadRoot.appendingPathComponent("app/package.json", isDirectory: false)
        let packageLock = payloadRoot.appendingPathComponent("app/package-lock.json", isDirectory: false)
        guard usableFile(packageManifest), usableFile(packageLock),
              let manifestData = readData(packageManifest.path),
              let lockData = readData(packageLock.path),
              (try? JSONSerialization.jsonObject(with: manifestData)) is [String: Any],
              (try? JSONSerialization.jsonObject(with: lockData)) is [String: Any] else {
            return "The bundled Gateway package manifest is missing or invalid. Rebuild or reinstall Tron."
        }

        let dependencies = payloadRoot.appendingPathComponent("app/node_modules", isDirectory: true)
        guard fileExists(dependencies.path) else {
            return "The bundled Gateway dependencies are missing. Rebuild or reinstall Tron."
        }

        let requiredDependencyFiles = [
            "@earendil-works/pi-agent-core/package.json",
            "@earendil-works/pi-ai/package.json",
            "@earendil-works/pi-coding-agent/package.json",
            "@earendil-works/pi-tui/package.json",
            "node-pty/package.json",
            "proper-lockfile/package.json",
            "ws/package.json",
        ]
        for relativePath in requiredDependencyFiles {
            let dependency = dependencies.appendingPathComponent(relativePath, isDirectory: false)
            guard usableFile(dependency) else {
                return "The bundled Gateway dependency tree is incomplete. Rebuild or reinstall Tron."
            }
        }

        let nodePtyHelper = payloadRoot
            .appendingPathComponent("app/scripts/ensure-node-pty-helper.mjs", isDirectory: false)
        let updateHelper = payloadRoot
            .appendingPathComponent("app/scripts/gateway-payload-deploy.mjs", isDirectory: false)
        guard usableFile(nodePtyHelper), usableFile(updateHelper) else {
            return "The bundled Gateway helper scripts are missing. Rebuild or reinstall Tron."
        }

        for architecture in ["arm64", "x64"] {
            let runtime = payloadRoot
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("node-\(architecture)", isDirectory: false)
            guard usableFile(runtime, minimumBytes: 1_048_576) else {
                return "The bundled Node \(architecture) runtime is missing or incomplete. Rebuild or reinstall Tron."
            }
            guard isExecutable(runtime.path) else {
                return "The bundled Node \(architecture) runtime is not executable. Rebuild or reinstall Tron."
            }
        }
        return nil
    }

    static func launchAgentPlistIsCurrent(
        plistPath: URL = TronPaths.launchAgentPlistPath,
        label: String = TronPaths.launchAgentLabel,
        port: Int = TronPaths.defaultServerPort,
        bundleProgram expectedBundleProgram: String = TronPaths.serverHelperBundleProgram,
        environmentVariables expectedEnvironmentVariables: [String: String] = TronPaths.launchAgentEnvironmentVariables,
        associatedBundleIDs expectedAssociatedBundleIDs: [String] = TronPaths.associatedWrapperBundleIDs
    ) -> Bool {
        guard let data = try? Data(contentsOf: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let plistLabel = plist["Label"] as? String,
              let bundleProgram = plist["BundleProgram"] as? String,
              let args = plist["ProgramArguments"] as? [String],
              let runAtLoad = plist["RunAtLoad"] as? Bool,
              let keepAlive = plist["KeepAlive"] as? Bool,
              let environmentVariables = plist["EnvironmentVariables"] as? [String: String],
              let associatedBundleIDs = plist["AssociatedBundleIdentifiers"] as? [String] else {
            return false
        }
        return plistLabel == label
            && bundleProgram == expectedBundleProgram
            && args == ["tron", "--host", "tailscale", "--port", "\(port)"]
            && runAtLoad
            && keepAlive
            && environmentVariables == expectedEnvironmentVariables
            && associatedBundleIDs == expectedAssociatedBundleIDs
    }

    static func launchAgentPlistIsCurrent(
        profile: TronGatewayProfile,
        plistPath: URL? = nil
    ) -> Bool {
        launchAgentPlistIsCurrent(
            plistPath: plistPath ?? TronPaths.launchAgentPlistPath(profile: profile),
            label: profile.launchAgentLabel,
            port: profile.port,
            bundleProgram: TronPaths.serverHelperBundleProgram(profile: profile),
            environmentVariables: TronPaths.launchAgentEnvironmentVariables(profile: profile),
            associatedBundleIDs: TronPaths.associatedWrapperBundleIDs(profile: profile)
        )
    }

    /// Reads `CFBundleShortVersionString` from `<Bundle>/Contents/Info.plist`.
    /// Returns nil if the file doesn't exist or can't be parsed.
    static func readMarketingVersion(of bundle: URL) -> String? {
        let infoPlistURL = bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Returns nil when the helper app's code signature is suitable for TCC.
    static func bundleSignatureProblem(
        of bundle: URL,
        expectedBundleIdentifier: String = TronPaths.launchAgentLabel
    ) -> String? {
        let helperName = bundle.lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "--verbose=2", bundle.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "\(helperName) is present but its code signature could not be checked"
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return "\(helperName) is present but its code signature is invalid"
        }

        let identity = Process()
        identity.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        identity.arguments = ["-dv", "--verbose=4", bundle.path]
        let identityOutput = Pipe()
        identity.standardOutput = identityOutput
        identity.standardError = identityOutput
        do {
            try identity.run()
            identity.waitUntilExit()
        } catch {
            return "\(helperName) is present but its code signature identity could not be checked"
        }
        let identityText = String(data: identityOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard identity.terminationStatus == 0 else {
            return "\(helperName) is present but its code signature identity is invalid"
        }
        if let problem = codeSignatureIdentityProblem(
            identityText,
            expectedBundleIdentifier: expectedBundleIdentifier,
            helperName: helperName
        ) {
            return problem
        }
        _ = text
        return nil
    }

    static func codeSignatureIdentityProblem(
        _ identityText: String,
        expectedBundleIdentifier: String = TronPaths.launchAgentLabel,
        helperName: String = "\(TronPaths.agentBundleName).app"
    ) -> String? {
        let identifier = identityText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("Identifier=") })
            .map { String($0.dropFirst("Identifier=".count)) }
        guard identifier == expectedBundleIdentifier else {
            return "\(helperName) is present but its code signature is not bound to \(expectedBundleIdentifier)"
        }
        if identityText.contains("Signature=adhoc")
            || identityText.contains("TeamIdentifier=not set") {
            return "\(helperName) is ad-hoc signed. Build Debug with Apple Development signing so macOS can launch the Login Item."
        }
        return nil
    }
}
