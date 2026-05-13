import Foundation

// MARK: - plugin source Server Types

/// Health state for a single plugin source server (matches Rust McpServerHealth).
enum PluginSourceHealth: String, Decodable, Sendable {
    case healthy
    case degraded
    case failed
}

/// Status snapshot for a single plugin source server (matches Rust McpServerStatus).
struct PluginSourceStatus: Decodable, Identifiable, Sendable {
    let name: String
    let health: PluginSourceHealth
    let toolCount: Int
    let consecutiveFailures: Int
    let lastError: String?
    let connectedAt: String?

    var id: String { name }

    var isConnected: Bool {
        health != .failed
    }
}

/// Configuration for adding a new plugin source server via pluginSources.addServer.
struct PluginSourceAddParams: Encodable {
    let name: String
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let enabled: Bool?
}

/// Params requiring only a server name.
struct PluginSourceNameParams: Encodable {
    let name: String
}

// MARK: - plugin source Engine Responses

struct PluginSourceAddResult: Decodable {
    let success: Bool
    let toolCount: Int
}

struct PluginSourceRestartResult: Decodable {
    let success: Bool
    let toolCount: Int
}

struct PluginSourceReloadResult: Decodable {
    let success: Bool
    let serverCount: Int
}

struct PluginSourceSuccessResult: Decodable {
    let success: Bool
}

// MARK: - plugin source Tool Listing

/// A tool discovered from an plugin source server (matches Rust ToolMatch).
struct PluginCapabilityInfo: Decodable, Identifiable, Sendable {
    let server: String
    let tool: String
    let description: String
    let params: [PluginCapabilityParam]
    let score: Int

    var id: String { "\(server).\(tool)" }
}

/// Parameter summary for an plugin source tool (matches Rust ParamSummary).
struct PluginCapabilityParam: Decodable, Identifiable, Sendable {
    let name: String
    let paramType: String
    let required: Bool
    let description: String

    var id: String { name }
}
