import Foundation

// MARK: - MCP Server Types

/// Health state for a single MCP server (matches Rust McpServerHealth).
enum MCPServerHealth: String, Decodable, Sendable {
    case healthy
    case degraded
    case failed
}

/// Status snapshot for a single MCP server (matches Rust McpServerStatus).
struct MCPServerStatus: Decodable, Identifiable, Sendable {
    let name: String
    let health: MCPServerHealth
    let toolCount: Int
    let consecutiveFailures: Int
    let lastError: String?
    let connectedAt: String?

    var id: String { name }

    var isConnected: Bool {
        health != .failed
    }
}

/// Configuration for adding a new MCP server via mcp.addServer.
struct MCPAddServerParams: Encodable {
    let name: String
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let enabled: Bool?
}

/// Params requiring only a server name.
struct MCPServerNameParams: Encodable {
    let name: String
}

// MARK: - MCP RPC Responses

struct MCPAddServerResult: Decodable {
    let success: Bool
    let toolCount: Int
}

struct MCPRestartServerResult: Decodable {
    let success: Bool
    let toolCount: Int
}

struct MCPReloadResult: Decodable {
    let success: Bool
    let serverCount: Int
}

struct MCPSuccessResult: Decodable {
    let success: Bool
}
