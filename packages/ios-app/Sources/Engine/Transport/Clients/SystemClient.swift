import Foundation
import CryptoKit

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
            idempotencyKey: DeviceRegistrationIdempotency.key(
                bundleId: bundleId,
                environment: environment,
                deviceId: deviceId,
                token: token
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

enum DeviceRegistrationIdempotency {
    static func key(
        bundleId: String,
        environment: String,
        deviceId: String,
        token: String
    ) -> EngineIdempotencyKey {
        let registrationDigest = SHA256.hash(
            data: Data("\(deviceId)\u{0}\(token)".utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
        return EngineIdempotencyKey(
            rawValue: "ios:device-register:v4:\(bundleId):\(environment):\(registrationDigest)"
        )
    }
}

enum DeviceInstallationIdentity {
    private static let storageKey = "tron.deviceInstallationId"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        // This identity belongs to one app installation. A vendor-scoped
        // device identity would let side-by-side Tron apps overwrite each
        // other's APNs registrations.
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: storageKey)
        return identifier
    }
}
