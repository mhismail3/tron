import Foundation

// MARK: - System Methods

struct SystemInfoResult: Decodable {
    let version: String
    let uptime: Int
    let activeSessions: Int
}

struct SystemPingResult: Decodable {
    let pong: Bool
}

// MARK: - Device Token Methods (Push Notifications)

/// Parameters for device.register
struct DeviceTokenRegisterParams: Encodable {
    let deviceToken: String
    let sessionId: String?
    let workspaceId: String?
    let environment: String
}

/// Result of device.register
struct DeviceTokenRegisterResult: Decodable {
    let id: String
    let created: Bool
}

/// Parameters for device.unregister
struct DeviceTokenUnregisterParams: Encodable {
    let deviceToken: String
}

/// Result of device.unregister
struct DeviceTokenUnregisterResult: Decodable {
    let success: Bool
}
