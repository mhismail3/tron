import Foundation

/// Explicit runtime identities for the Release-owned Stable Gateway and the
/// read-only developer-owned Debug projection.
struct TronGatewayProfile: Equatable, Sendable {
    let name: String
    let launchAgentLabel: String
    let channel: String
    let homeName: String
    let agentDirectoryName: String
    let port: Int
    let agentBundleName: String

    static let stable = TronGatewayProfile(
        name: "stable", launchAgentLabel: "com.tron.server", channel: "stable",
        homeName: ".tron", agentDirectoryName: "agent", port: 9847, agentBundleName: "Tron Agent"
    )
    /// Developer-owned Debug Gateway. Installed Release may authenticate to
    /// and report this profile, but no Mac wrapper manages its lifecycle.
    static let debug = TronGatewayProfile(
        name: "debug", launchAgentLabel: "com.tron.server.dev", channel: "dev",
        homeName: ".tron-dev", agentDirectoryName: "agent-dev", port: 9848, agentBundleName: "Tron Agent Dev"
    )
}

/// Canonical Tron-home, gateway-state, and bundle paths owned by the wrapper.
enum TronPaths {
    private enum HomeComponent {
        static let internalDir = "internal"
        static let runDir = "run"
        static let networkCacheFile = "network.json"
    }

    static let tronDataDirEnv = "TRON_DATA_DIR"
    static let tronHomeNameEnv = "TRON_HOME_NAME"
    static let agentDirNameEnv = "TRON_AGENT_DIR_NAME"
    static let gatewaySupervisionEnv = "TRON_GATEWAY_SUPERVISED"
    static let gatewaySupervisionValue = "1"
    /// Selects the externally staged payload namespace under the selected Tron home.
    static let gatewayChannelEnv = "TRON_GATEWAY_CHANNEL"
    static let productionGatewayChannel = TronGatewayProfile.stable.channel
    static let productionLaunchAgentLabel = TronGatewayProfile.stable.launchAgentLabel
    static let productionServerPort = TronGatewayProfile.stable.port

    static let homeDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
    }()

    static let tronHome: URL = {
        tronHome(environment: ProcessInfo.processInfo.environment)
    }()

    static func tronHome(environment: [String: String]) -> URL {
        if let override = environment[tronDataDirEnv], !override.isEmpty {
            precondition(override.hasPrefix("/"), "\(tronDataDirEnv) must be an absolute path")
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let homeName = environment[tronHomeNameEnv], !homeName.isEmpty {
            precondition(validHomeName(homeName), "\(tronHomeNameEnv) must be a single home-relative directory name")
            return homeDirectory.appendingPathComponent(homeName, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".tron", isDirectory: true)
    }

    static func tronHome(profile: TronGatewayProfile) -> URL {
        homeDirectory.appendingPathComponent(profile.homeName, isDirectory: true)
    }

    static func agentHome(profile: TronGatewayProfile) -> URL {
        homeDirectory.appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent(profile.agentDirectoryName, isDirectory: true)
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
    static var runDir: URL { internalDir.appendingPathComponent(HomeComponent.runDir, isDirectory: true) }

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

    static var gatewayPayloadRoot: URL {
        applicationBundle
            .appendingPathComponent("Contents/Resources/Gateway", isDirectory: true)
    }

    static var gatewayEntrypoint: URL {
        gatewayPayloadRoot
            .appendingPathComponent("app/dist/index.js", isDirectory: false)
    }

    static var gatewayProductionDependencies: URL {
        gatewayPayloadRoot
            .appendingPathComponent("app/node_modules", isDirectory: true)
    }

    static func gatewayNodeRuntime(architecture: String) -> URL {
        gatewayPayloadRoot
            .appendingPathComponent("runtime/node-\(architecture)", isDirectory: false)
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

    static var authLockPath: URL {
        runDir.appendingPathComponent("auth.lock", isDirectory: false)
    }

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
        serverHelperBundleProgram(environment: ProcessInfo.processInfo.environment)
    }

    static func serverHelperBundleProgram(profile: TronGatewayProfile) -> String {
        "Contents/Library/LoginItems/\(profile.agentBundleName).app/Contents/MacOS/tron"
    }

    static func serverHelperBundleProgram(environment: [String: String]) -> String {
        "Contents/Library/LoginItems/\(agentBundleName(environment: environment)).app/Contents/MacOS/tron"
    }

    static var launchAgentLabel: String {
        launchAgentLabel(environment: ProcessInfo.processInfo.environment)
    }

    static func launchAgentLabel(profile: TronGatewayProfile) -> String { profile.launchAgentLabel }

    static func launchAgentLabel(environment: [String: String]) -> String {
        activeProfile(environment: environment).launchAgentLabel
    }

    static func profile(_ profile: TronGatewayProfile) -> TronGatewayProfile { profile }

    static var defaultServerPort: Int {
        defaultServerPort(environment: ProcessInfo.processInfo.environment)
    }

    static func defaultServerPort(profile: TronGatewayProfile) -> Int { profile.port }

    static func defaultServerPort(environment: [String: String]) -> Int {
        activeProfile(environment: environment).port
    }

    static var launchAgentEnvironmentVariables: [String: String] {
        launchAgentEnvironmentVariables(environment: ProcessInfo.processInfo.environment)
    }

    static func launchAgentEnvironmentVariables(profile: TronGatewayProfile) -> [String: String] {
        var values = [gatewaySupervisionEnv: gatewaySupervisionValue, gatewayChannelEnv: profile.channel]
        if profile == .debug {
            values[tronHomeNameEnv] = profile.homeName
            values[agentDirNameEnv] = profile.agentDirectoryName
        }
        return values
    }

    static func launchAgentEnvironmentVariables(environment: [String: String]) -> [String: String] {
        launchAgentEnvironmentVariables(profile: activeProfile(environment: environment))
    }

    static var canManageLaunchAgent: Bool {
        canManageLaunchAgent(environment: ProcessInfo.processInfo.environment)
    }

    static func canManageLaunchAgent(profile: TronGatewayProfile, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard profile == .stable,
              MacRuntimeVariant.detect().canManageLaunchAgent(profile: profile, isIsolatedInstallMode: false) else { return false }
        return environment[tronDataDirEnv] == nil
            && environment[tronHomeNameEnv] == nil
            && environment[agentDirNameEnv] == nil
    }

    static func canManageLaunchAgent(environment: [String: String]) -> Bool {
        canManageLaunchAgent(profile: activeProfile(environment: environment), environment: environment)
    }
    static var agentBundleName: String {
        agentBundleName(environment: ProcessInfo.processInfo.environment)
    }

    static func agentBundleName(environment: [String: String]) -> String {
        activeProfile(environment: environment).agentBundleName
    }
    /// Stable has exactly one wrapper parent. Debug lifecycle is CLI-owned and
    /// has no SMAppService parent.
    static var associatedWrapperBundleIDs: [String] {
        associatedWrapperBundleIDs(profile: activeProfile)
    }

    static func associatedWrapperBundleIDs(profile: TronGatewayProfile) -> [String] {
        profile == .stable ? [MacRuntimeVariant.releaseBundleIdentifier] : []
    }

    static func activeProfile(environment: [String: String] = ProcessInfo.processInfo.environment) -> TronGatewayProfile {
        .stable
    }

    static var activeProfile: TronGatewayProfile { activeProfile(environment: ProcessInfo.processInfo.environment) }


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
