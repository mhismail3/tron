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

// MARK: - Diagnostics (debug / beta only)

#if DEBUG || BETA
/// Result of `system.getDiagnostics`.
///
/// A structured snapshot of server identity, session counts, and RPC
/// surface area. Drives the in-app debug panel and exists only in DEBUG
/// / BETA builds to avoid bloating the production binary with debug UI
/// state.
struct SystemDiagnosticsResult: Decodable {
    let server: ServerIdentity
    let sessions: SessionCounts
    let rpc: RpcSurface
    let timestamp: String

    struct ServerIdentity: Decodable {
        let version: String
        let protocolVersion: Int
        let minClientProtocolVersion: Int
        let platform: String
        let arch: String
        let pid: Int
        let uptimeSeconds: Int
        let origin: String?
    }

    struct SessionCounts: Decodable {
        let active: Int
        let activeRuns: Int
    }

    struct RpcSurface: Decodable {
        let totalMethods: Int
        /// Map of prefix ("session", "agent", ...) -> count. Stable order
        /// from server (BTreeMap) but Swift dictionary iteration isn't
        /// guaranteed — consumers sort when rendering.
        let methodsByGroup: [String: Int]
        let methods: [String]
    }
}
#endif

// MARK: - Device Token Methods (Push Notifications)

/// Parameters for device.register
struct DeviceTokenRegisterParams: Encodable {
    let deviceToken: String
    let sessionId: String?
    let workspaceId: String?
    let environment: String
    /// APNs bundle ID the token was issued against (e.g.,
    /// `com.tron.mobile` vs `com.tron.mobile.beta`). The server stores it
    /// and the relay uses it as `apns-topic` — without it, Beta-scheme
    /// tokens get rejected with `DeviceTokenNotForTopic`.
    let bundleId: String
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

// MARK: - Logs Methods

#if DEBUG || BETA
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
#endif
