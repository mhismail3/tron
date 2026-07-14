import Foundation

/// Selects the process graph before any production dependency is evaluated.
enum AppRuntimeMode: Equatable, Sendable {
    case application
    case hostedUnitTests

    private static let hostedXCTestMarkers = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto",
    ]

    static var current: Self {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(environment: [String: String]) -> Self {
        if hostedXCTestMarkers.contains(where: { environment.keys.contains($0) }) {
            return .hostedUnitTests
        }
        return .application
    }

    var runsApplicationLifecycle: Bool {
        self == .application
    }
}
