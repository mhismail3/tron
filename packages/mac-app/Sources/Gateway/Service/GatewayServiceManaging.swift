import Foundation

enum GatewayServiceRegistrationStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case unavailable
}

enum GatewayServiceOutcome: Equatable, Sendable {
    case registered
    case alreadyRegistered
    case unregistered
    case requiresApproval
    case portInUse(Int)
    case invalidBundle
    case refused
    case failed

    var isSuccess: Bool {
        switch self {
        case .registered, .alreadyRegistered, .unregistered:
            true
        case .requiresApproval, .portInUse, .invalidBundle, .refused, .failed:
            false
        }
    }
}

struct GatewayRuntimeInfo: Equatable, Sendable {
    var pid: Int?
    var uptime: String?
    var parentBundleIdentifier: String?
    var parentBundleVersion: String?
    var programIdentifier: String?
}

/// The only process-control boundary used by the Mac app. The implementation
/// owns the current `SMAppService` registration; launchd owns the process.
protocol GatewayServiceManaging: Sendable {
    func registrationStatus(configuration: GatewayServiceConfiguration) async -> GatewayServiceRegistrationStatus
    func register(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome
    func unregister(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome
    func restart(configuration: GatewayServiceConfiguration) async -> GatewayServiceOutcome
    func isLoaded(configuration: GatewayServiceConfiguration) async -> Bool
    func runtimeInfo(configuration: GatewayServiceConfiguration) async -> GatewayRuntimeInfo?
}
