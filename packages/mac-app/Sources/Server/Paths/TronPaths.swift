import Foundation

/// Canonical Tron-home, gateway-state, and bundle paths owned by the wrapper.
enum TronPaths {
    private enum HomeComponent {
        static let internalDir = "internal"
        static let runDir = "run"
        static let networkCacheFile = "network.json"
    }

    static let tronDataDirEnv = "TRON_DATA_DIR"
    static let tronHomeNameEnv = "TRON_HOME_NAME"
    static let piCodingAgentDirEnv = "PI_CODING_AGENT_DIR"
    /// Recognized only to refuse wrapper ownership of an old unsupported profile.
    static let retiredAgentDirNameEnv = "TRON_AGENT_DIR_NAME"
    static let gatewaySupervisionEnv = "TRON_GATEWAY_SUPERVISED"
    static let gatewaySupervisionValue = "1"
    /// Selects the externally staged payload namespace under the selected Tron home.
    static let gatewayChannelEnv = "TRON_GATEWAY_CHANNEL"
    static let productionGatewayChannel = TronGatewayProfile.stable.channel

    static let homeDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
    }()

    static let tronHome: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[tronDataDirEnv], !override.isEmpty {
            precondition(override.hasPrefix("/"), "\(tronDataDirEnv) must be an absolute path")
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let homeName = environment[tronHomeNameEnv], !homeName.isEmpty {
            precondition(validHomeName(homeName), "\(tronHomeNameEnv) must be a single home-relative directory name")
            return homeDirectory.appendingPathComponent(homeName, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".tron", isDirectory: true)
    }()

    static func tronHome(profile: TronGatewayProfile) -> URL {
        // Stable is the wrapper-owned profile and follows the same explicit
        // whole-home overrides as Gateway config. Debug remains an isolated
        // profile and is never redirected by Stable's environment.
        if profile == .stable { return tronHome }
        return homeDirectory.appendingPathComponent(profile.homeName, isDirectory: true)
    }

    static func agentHome(profile: TronGatewayProfile) -> URL {
        if profile == .stable, let explicit = ProcessInfo.processInfo.environment[piCodingAgentDirEnv], !explicit.isEmpty {
            precondition(explicit.hasPrefix("/"), "\(piCodingAgentDirEnv) must be an absolute path")
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        return tronHome(profile: profile).appendingPathComponent(profile.agentDirectoryName, isDirectory: true)
    }

    static func bearerTokenPath(profile: TronGatewayProfile) -> URL {
        tronHome(profile: profile).appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("local-auth.json", isDirectory: false)
    }

    static func enrollmentCodePath(profile: TronGatewayProfile) -> URL {
        tronHome(profile: profile).appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("enrollment.json", isDirectory: false)
    }

    static func networkCachePath(profile: TronGatewayProfile) -> URL {
        tronHome(profile: profile).appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent(HomeComponent.networkCacheFile, isDirectory: false)
    }

    static func internalDir(profile: TronGatewayProfile) -> URL { tronHome(profile: profile).appendingPathComponent(HomeComponent.internalDir, isDirectory: true) }
    static func runDir(profile: TronGatewayProfile) -> URL { internalDir(profile: profile).appendingPathComponent(HomeComponent.runDir, isDirectory: true) }

    static var internalDir: URL { tronHome.appendingPathComponent(HomeComponent.internalDir, isDirectory: true) }

    static let releaseApplicationURL = URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)

    static var applicationBundle: URL { Bundle.main.bundleURL }
    static var loginItemsDir: URL {
        applicationBundle
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
    }
    static func serverHelperBundle(profile: TronGatewayProfile) -> URL {
        loginItemsDir.appendingPathComponent("\(profile.agentBundleName).app", isDirectory: true)
    }
    static func serverHelperBinary(profile: TronGatewayProfile) -> URL {
        serverHelperBundle(profile: profile)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
    }
    static var serverHelperBundle: URL { serverHelperBundle(profile: activeProfile) }
    static var serverHelperBinary: URL { serverHelperBinary(profile: activeProfile) }

    /// Dedicated Aqua host for TCC queries and explicit permission requests.
    /// Explicit setup registers its bundled agent; launchd then owns activation.
    static var nativeHostBundle: URL {
        applicationBundle.appendingPathComponent(NativeHostTrust.relativeBundlePath, isDirectory: true)
    }
    static var nativeHostExecutable: URL {
        nativeHostBundle.appendingPathComponent("Contents/MacOS/TronNativeHost", isDirectory: false)
    }
    static var gatewayPayloadRoot: URL {
        applicationBundle
            .appendingPathComponent("Contents/Resources/Gateway", isDirectory: true)
    }

    static var bearerTokenPath: URL { bearerTokenPath(profile: activeProfile) }
    static var enrollmentCodePath: URL { enrollmentCodePath(profile: activeProfile) }

    static func onboardedMarkerPath(profile: TronGatewayProfile) -> URL {
        runDir(profile: profile).appendingPathComponent(".onboarded", isDirectory: false)
    }
    static var onboardedMarkerPath: URL { onboardedMarkerPath(profile: activeProfile) }

    static func macAppVersionMarkerPath(profile: TronGatewayProfile) -> URL {
        runDir(profile: profile).appendingPathComponent("mac-app-version.json", isDirectory: false)
    }
    static var macAppVersionMarkerPath: URL { macAppVersionMarkerPath(profile: activeProfile) }

    static func macWrapperLockPath(profile: TronGatewayProfile) -> URL {
        runDir(profile: profile).appendingPathComponent(macWrapperLockFileName(bundleIdentifier: Bundle.main.bundleIdentifier), isDirectory: false)
    }
    static var macWrapperLockPath: URL { macWrapperLockPath(profile: activeProfile) }

    static var networkCachePath: URL { networkCachePath(profile: activeProfile) }

    static func launchAgentPlistPath(profile: TronGatewayProfile) -> URL {
        applicationBundle.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(profile.launchAgentLabel).plist", isDirectory: false)
    }
    static var launchAgentPlistPath: URL { launchAgentPlistPath(profile: activeProfile) }

    static var serverHelperBundleProgram: String {
        serverHelperBundleProgram(profile: activeProfile)
    }

    static func serverHelperBundleProgram(profile: TronGatewayProfile) -> String {
        "Contents/Library/LoginItems/\(profile.agentBundleName).app/Contents/MacOS/tron"
    }

    static var launchAgentLabel: String { activeProfile.launchAgentLabel }

    static func launchAgentLabel(profile: TronGatewayProfile) -> String { profile.launchAgentLabel }

    static var defaultServerPort: Int { activeProfile.port }

    static func defaultServerPort(profile: TronGatewayProfile) -> Int { profile.port }

    static var launchAgentEnvironmentVariables: [String: String] {
        launchAgentEnvironmentVariables(profile: activeProfile)
    }

    static func launchAgentEnvironmentVariables(profile: TronGatewayProfile) -> [String: String] {
        var values = [gatewaySupervisionEnv: gatewaySupervisionValue, gatewayChannelEnv: profile.channel]
        if profile == .stable {
            if let explicit = ProcessInfo.processInfo.environment[piCodingAgentDirEnv], !explicit.isEmpty {
                precondition(explicit.hasPrefix("/"), "\(piCodingAgentDirEnv) must be an absolute path")
                values[piCodingAgentDirEnv] = explicit
            }
        } else {
            values[tronHomeNameEnv] = profile.homeName
        }
        return values
    }

    static var canManageLaunchAgent: Bool {
        canManageLaunchAgent(profile: activeProfile)
    }

    static func canManageLaunchAgent(profile: TronGatewayProfile) -> Bool {
        guard profile == .stable,
              MacRuntimeVariant.detect().canManageLaunchAgent(profile: profile, isIsolatedInstallMode: false) else { return false }
        let environment = ProcessInfo.processInfo.environment
        return environment[tronDataDirEnv] == nil
            && environment[tronHomeNameEnv] == nil
            && environment[retiredAgentDirNameEnv] == nil
            && (environment[piCodingAgentDirEnv]?.isEmpty != false || environment[piCodingAgentDirEnv]!.hasPrefix("/"))
    }

    static var agentBundleName: String { activeProfile.agentBundleName }

    /// Stable has exactly one wrapper parent. Debug lifecycle is CLI-owned and
    /// has no SMAppService parent.
    static var associatedWrapperBundleIDs: [String] {
        associatedWrapperBundleIDs(profile: activeProfile)
    }

    static func associatedWrapperBundleIDs(profile: TronGatewayProfile) -> [String] {
        profile == .stable ? [MacRuntimeVariant.releaseBundleIdentifier] : []
    }

    /// The wrapper owns exactly one profile; Debug lifecycle is CLI-owned.
    static let activeProfile: TronGatewayProfile = .stable

    static func macWrapperLockFileName(bundleIdentifier: String?) -> String {
        let rawIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "unknown"
        let safeIdentifier = rawIdentifier.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == UnicodeScalar(".")
                || scalar == UnicodeScalar("-") {
                return Character(scalar)
            }
            return "-"
        }
        return ".mac-wrapper.\(String(safeIdentifier)).lock"
    }

    private static func validHomeName(_ value: String) -> Bool {
        value != "." && value != ".." && !value.contains("/")
    }
}
