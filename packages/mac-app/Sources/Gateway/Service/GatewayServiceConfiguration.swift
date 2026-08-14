import Foundation

/// Immutable, fully resolved service identity used by every Gateway owner.
/// Callers never infer labels, ports, or paths independently.
struct GatewayServiceConfiguration: Equatable, Sendable {
    let mode: GatewayRuntimeMode
    let tronHome: URL
    let applicationBundle: URL
    let gatewayDirectory: URL
    let bearerTokenPath: URL
    let enrollmentCodePath: URL
    let appStatePath: URL
    let wrapperLockPath: URL
    let servicePlistPath: URL
    let serviceLabel: String
    let helperName: String
    let helperBundle: URL
    let helperBinary: URL
    let helperBundleProgram: String
    let gatewayPort: Int
    let serviceEnvironment: [String: String]
    let associatedWrapperBundleIdentifiers: [String]

    var applicationLocationProblem: String? {
        mode.applicationLocationProblem(bundleURL: applicationBundle)
    }
}
