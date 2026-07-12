import Foundation
import CryptoKit
import UIKit

/// Client for system-level engine operations.
final class SystemClient: EngineDomainClient {

    func ping() async throws {
        _ = try requireTransport().requireConnection()

        let _: SystemPingResult = try await invokeRead(
            "system::ping",
            SystemPingParams(
                protocolVersion: 1,
                clientVersion: AppConstants.canonicalVersion
            )
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_info",
            EmptyParams()
        )
    }

    func registerDeviceToken(_ token: String) async throws -> DeviceRegistrationResult {
        _ = try requireTransport().requireConnection()
        let environment = APNsEnvironment.current()
        guard let bundleId = Bundle.main.bundleIdentifier else {
            throw EngineClientError.invalidURL
        }
        let deviceId = DeviceInstallationIdentity.current()
        let tokenDigest = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try await invokeWrite(
            "device::register",
            DeviceRegistrationParams(
                deviceId: deviceId,
                platform: "ios",
                apnsEnvironment: environment,
                apnsToken: token,
                bundleId: bundleId,
                pushOptIn: true,
                pushEnabled: true
            ),
            idempotencyKey: EngineIdempotencyKey(
                rawValue: "ios:device-register:\(bundleId):\(environment):\(tokenDigest)"
            )
        )
    }

}

struct DeviceRegistrationParams: Encodable {
    let deviceId: String
    let platform: String
    let apnsEnvironment: String
    let apnsToken: String
    let bundleId: String
    let pushOptIn: Bool
    let pushEnabled: Bool
}

struct DeviceRegistrationResult: Decodable, Equatable {
    let status: String
    let idempotentReplay: Bool
    let apnsTokenRedacted: Bool
    let liveApnsEnabled: Bool
}

private enum DeviceInstallationIdentity {
    private static let storageKey = "tron.deviceInstallationId"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(identifier, forKey: storageKey)
        return identifier
    }
}
