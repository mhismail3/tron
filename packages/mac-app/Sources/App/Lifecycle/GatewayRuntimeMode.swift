import Foundation

/// The Mac wrapper has exactly two service-owning modes.
enum GatewayRuntimeMode: Equatable, Sendable {
    case production
    case development

    static let productionBundleIdentifier = "com.tron.mac"
    static let developmentBundleIdentifier = "com.tron.mac.dev"

    static func detect(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> GatewayRuntimeMode? {
        switch bundleIdentifier {
        case productionBundleIdentifier:
            return .production
        case developmentBundleIdentifier:
            return .development
        default:
            return nil
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .production: Self.productionBundleIdentifier
        case .development: Self.developmentBundleIdentifier
        }
    }

    func applicationLocationProblem(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        guard self == .production else { return nil }
        guard bundleURL.standardizedFileURL.path == GatewayPaths.productionApplicationURL.standardizedFileURL.path else {
            return "Move Tron.app to /Applications before installing Tron."
        }
        return nil
    }
}
