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

// MARK: - MCP Tool Listing

/// A tool discovered from an MCP server (matches Rust ToolMatch).
struct MCPToolInfo: Decodable, Identifiable, Sendable {
    let server: String
    let tool: String
    let description: String
    let params: [MCPToolParam]
    let score: Int

    var id: String { "\(server).\(tool)" }
}

/// Parameter summary for an MCP tool (matches Rust ParamSummary).
struct MCPToolParam: Decodable, Identifiable, Sendable {
    let name: String
    let paramType: String
    let required: Bool
    let description: String

    var id: String { name }
}
