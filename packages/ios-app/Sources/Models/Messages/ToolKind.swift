import Foundation

/// Canonical tool kind with case-insensitive matching.
/// Eliminates scattered `.lowercased() == "..."` comparisons.
enum ToolKind: Sendable, Equatable {
    case askUserQuestion
    case getConfirmation
    case bash
    case read
    case write
    case edit
    case search
    case glob
    case spawnSubagent
    case waitForSubagent
    case queryAgent
    case notifyApp
    case manageAutomations
    case mcpSearch
    case mcpCall
    case other(String)

    init(toolName: String) {
        switch toolName.lowercased() {
        case "askuserquestion":   self = .askUserQuestion
        case "getconfirmation":   self = .getConfirmation
        case "bash":              self = .bash
        case "read":              self = .read
        case "write":             self = .write
        case "edit":              self = .edit
        case "search":            self = .search
        case "glob", "find":      self = .glob
        case "spawnsubagent":     self = .spawnSubagent
        case "waitforsubagent":   self = .waitForSubagent
        case "queryagent":        self = .queryAgent
        case "notifyapp":         self = .notifyApp
        case "manageautomations": self = .manageAutomations
        case "mcpsearch":         self = .mcpSearch
        case "mcpcall":           self = .mcpCall
        default:                  self = .other(toolName)
        }
    }
}
