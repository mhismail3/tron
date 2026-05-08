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

struct SystemPingParams: Encodable {
    let protocolVersion: Int
    let clientVersion: String
}

// MARK: - Update Checks

/// Result of `system.checkForUpdates` — a forced GitHub Releases probe.
///
/// The server caches the upstream response for 60s to avoid API rate-limit
/// thrash, so back-to-back calls from the iOS UI return the same snapshot.
/// All fields except `available` are optional because the server may still
/// surface a successful "no release found" response even when the network
/// is intact (e.g. empty releases list, or the configured channel
/// filtered everything out).
struct SystemCheckForUpdatesResult: Decodable {
    /// `true` if a newer version exists for the configured channel.
    let available: Bool
    /// The matched release's semver (e.g. `"0.1.1"`). `nil` when nothing
    /// beats the current running version.
    let latestVersion: String?
    /// Direct DMG download URL. `nil` when `available == false`.
    let downloadUrl: String?
    /// GitHub release notes in markdown. `nil` when `available == false`.
    let releaseNotes: String?
    /// The channel evaluated for this check (`"stable"` / `"beta"`). Mirrored
    /// back so UI can show "Checking Beta channel…" without re-reading
    /// settings.
    let channel: String?
}

/// Result of `system.getUpdateStatus` — snapshot of the updater state file
/// plus the currently-configured settings.
struct SystemUpdateStatusResult: Decodable {
    /// Current running server version.
    let currentVersion: String
    /// The configured channel (`"stable"` / `"beta"`).
    let channel: String
    /// The configured check frequency.
    let frequency: String
    /// The configured action on a found update.
    let action: String
    /// Master enabled flag.
    let enabled: Bool
    /// RFC3339 timestamp of the last check attempt. `nil` if never checked.
    let lastCheckAt: String?
    /// Last version the updater installed (if any). `nil` if never installed.
    let lastInstalledVersion: String?
    /// Latest known version from the most recent successful check. `nil`
    /// if no check has landed yet.
    let latestAvailableVersion: String?
    /// Latest known download URL.
    let latestDownloadUrl: String?
}

// MARK: - Diagnostics (debug / beta only)

#if DEBUG || BETA
/// Result of `system.getDiagnostics`.
///
/// A structured snapshot of server identity, session counts, and engine protocol
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

struct LogsRecentParams: Encodable {
    let limit: Int?
}

struct LogsRecentResult: Decodable, Sendable {
    let entries: [RecentLogEntry]
    let count: Int
}

struct RecentLogEntry: Decodable, Sendable {
    let id: Int64
    let timestamp: String
    let level: String
    let component: String
    let message: String
    let origin: String?
    let sessionId: String?
    let errorMessage: String?
}

/// A single log entry for ingestion into the server database.
struct ClientLogEntry: Encodable {
    let timestamp: String   // ISO 8601 with millis ("2026-03-03T14:30:05.123Z")
    let level: String       // "verbose", "debug", "info", "warning", "error"
    let category: String    // "WebSocket", "engine protocol", etc.
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
