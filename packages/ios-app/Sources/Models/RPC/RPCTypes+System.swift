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

// MARK: - Device Request Methods

/// Parameters for device.respond
struct DeviceRespondParams: Encodable {
    let requestId: String
    let result: AnyCodable
}

/// Result of device.respond
struct DeviceRespondResult: Decodable {
    let resolved: Bool
}

// MARK: - Logs Methods

/// A single log entry for ingestion into the server database.
struct ClientLogEntry: Encodable {
    let timestamp: String   // ISO 8601 with millis ("2026-03-03T14:30:05.123Z")
    let level: String       // "verbose", "debug", "info", "warning", "error"
    let category: String    // "WebSocket", "RPC", etc.
    let message: String
}

/// Parameters for logs.ingest
struct LogsIngestParams: Encodable {
    let entries: [ClientLogEntry]
}

/// Result of logs.ingest
struct LogsIngestResult: Decodable {
    let success: Bool
    let inserted: Int
}
