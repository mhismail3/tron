import Foundation
import SwiftUI

protocol GatewayCredentialReading: Sendable {
    func bearerToken() -> String?
    func enrollmentCode() -> String?
}

struct FileGatewayCredentialReader: GatewayCredentialReading {
    let configuration: GatewayServiceConfiguration

    func bearerToken() -> String? {
        GatewayBearerTokenReader.read(at: configuration.bearerTokenPath)
    }

    func enrollmentCode() -> String? {
        GatewayEnrollmentCodeReader.read(at: configuration.enrollmentCodePath)
    }
}

protocol GatewaySystemRequirementsChecking: Sendable {
    func tailscaleStatus() async -> TailscaleStatus
    func permissionStatuses() async -> [Permission: PermissionStatus]
}

struct LiveGatewaySystemRequirements: GatewaySystemRequirementsChecking {
    func tailscaleStatus() async -> TailscaleStatus { await TailscaleProbe.probe() }
    func permissionStatuses() async -> [Permission: PermissionStatus] { await MacPermissionProbe.probeAll() }
}

protocol GatewayHealthChecking: Sendable {
    func check(bearerToken: String?) async -> GatewayHealthResult
}

struct LiveGatewayHealthChecker: GatewayHealthChecking {
    let configuration: GatewayServiceConfiguration
    let requirements: any GatewaySystemRequirementsChecking

    func check(bearerToken: String?) async -> GatewayHealthResult {
        guard case .signedIn(let host) = await requirements.tailscaleStatus() else {
            return .unreachable
        }
        return await GatewayHealthClient.ping(
            host: host,
            port: configuration.gatewayPort,
            token: bearerToken
        )
    }
}

struct GatewayHealthPolicy: Equatable, Sendable {
    var attempts = 60
    var delayNanoseconds: UInt64 = 1_000_000_000
}

/// Composition root made from narrow, independently testable boundaries.
struct GatewayDependencies: Sendable {
    let configuration: GatewayServiceConfiguration
    let serviceManager: any GatewayServiceManaging
    let healthChecker: any GatewayHealthChecking
    let stateStore: any GatewayStatePersisting
    let requirements: any GatewaySystemRequirementsChecking
    let credentials: any GatewayCredentialReading
    let currentVersion: GatewayAppVersion
    let healthPolicy: GatewayHealthPolicy

    static let live: GatewayDependencies = {
        let configuration = GatewayPaths.liveConfiguration
        let requirements = LiveGatewaySystemRequirements()
        return GatewayDependencies(
            configuration: configuration,
            serviceManager: LiveGatewayServiceManager(),
            healthChecker: LiveGatewayHealthChecker(
                configuration: configuration,
                requirements: requirements
            ),
            stateStore: FileGatewayStateStore(path: configuration.appStatePath),
            requirements: requirements,
            credentials: FileGatewayCredentialReader(configuration: configuration),
            currentVersion: .current(),
            healthPolicy: GatewayHealthPolicy()
        )
    }()
}

private struct GatewayDependenciesKey: EnvironmentKey {
    static let defaultValue: GatewayDependencies = .live
}

extension EnvironmentValues {
    var gatewayDependencies: GatewayDependencies {
        get { self[GatewayDependenciesKey.self] }
        set { self[GatewayDependenciesKey.self] = newValue }
    }
}
