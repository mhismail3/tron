import Foundation

/// Canonical identities and paths for the two supported Mac Gateway modes.
///
/// Production always owns `/Applications/Tron.app`, `~/.tron`, and port 9847.
/// Xcode development always owns its isolated service, `~/.tron-dev`, and port
/// 9848. Configuration is selected only from the wrapper bundle identity.
enum GatewayPaths {
    static let productionServiceLabel = "com.tron.gateway"
    static let developmentServiceLabel = "com.tron.gateway.dev"
    static let productionGatewayPort = 9847
    static let developmentGatewayPort = 9848
    static let productionApplicationURL = URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)

    static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    static func configuration(
        mode: GatewayRuntimeMode,
        applicationBundle: URL = Bundle.main.bundleURL,
        homeDirectory: URL = homeDirectory,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> GatewayServiceConfiguration {
        let homeName = mode == .production ? ".tron" : ".tron-dev"
        let serviceLabel = mode == .production ? productionServiceLabel : developmentServiceLabel
        let helperName = mode == .production ? "Tron Gateway" : "Tron Gateway Dev"
        let gatewayPort = mode == .production ? productionGatewayPort : developmentGatewayPort
        let tronHome = homeDirectory.appendingPathComponent(homeName, isDirectory: true)
        let gatewayDirectory = tronHome.appendingPathComponent("gateway", isDirectory: true)
        let loginItemsDirectory = applicationBundle
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        let helperBundle = loginItemsDirectory
            .appendingPathComponent("\(helperName).app", isDirectory: true)
        let helperBinary = helperBundle
            .appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let launchAgentsDirectory = applicationBundle
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        let safeBundleIdentifier = lockIdentifier(bundleIdentifier)

        return GatewayServiceConfiguration(
            mode: mode,
            tronHome: tronHome,
            applicationBundle: applicationBundle,
            gatewayDirectory: gatewayDirectory,
            bearerTokenPath: gatewayDirectory.appendingPathComponent("local-auth.json", isDirectory: false),
            enrollmentCodePath: gatewayDirectory.appendingPathComponent("enrollment.json", isDirectory: false),
            appStatePath: gatewayDirectory.appendingPathComponent("mac-app-state.json", isDirectory: false),
            wrapperLockPath: gatewayDirectory.appendingPathComponent("mac-app.\(safeBundleIdentifier).lock", isDirectory: false),
            servicePlistPath: launchAgentsDirectory.appendingPathComponent("\(serviceLabel).plist", isDirectory: false),
            serviceLabel: serviceLabel,
            helperName: helperName,
            helperBundle: helperBundle,
            helperBinary: helperBinary,
            helperBundleProgram: "Contents/Library/LoginItems/\(helperName).app/Contents/MacOS/tron",
            gatewayPort: gatewayPort,
            serviceEnvironment: mode == .production ? [:] : ["TRON_HOME_NAME": ".tron-dev"],
            associatedWrapperBundleIdentifiers: [mode.bundleIdentifier]
        )
    }

    static var liveConfiguration: GatewayServiceConfiguration {
        guard let mode = GatewayRuntimeMode.detect(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            preconditionFailure("Unsupported Tron bundle identifier")
        }
        return configuration(mode: mode)
    }

    private static func lockIdentifier(_ bundleIdentifier: String?) -> String {
        let raw = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "unknown"
        return String(raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == UnicodeScalar(".")
                || scalar == UnicodeScalar("-") {
                return Character(scalar)
            }
            return "-"
        })
    }
}
