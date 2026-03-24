import Foundation

/// Canonical tool kind with case-insensitive matching.
/// Eliminates scattered `.lowercased() == "..."` comparisons.
enum ToolKind: Sendable, Equatable {
    case askUserQuestion
    case bash
    case read
    case write
    case edit
    case search
    case glob
    case spawnSubagent
    case waitForSubagent
    case waitForAgents
    case queryAgent
    case notifyApp
    case manageAutomations
    case other(String)

    init(toolName: String) {
        switch toolName.lowercased() {
        case "askuserquestion":   self = .askUserQuestion
        case "bash":              self = .bash
        case "read":              self = .read
        case "write":             self = .write
        case "edit":              self = .edit
        case "search":            self = .search
        case "glob", "find":      self = .glob
        case "spawnsubagent":     self = .spawnSubagent
        case "waitforsubagent":   self = .waitForSubagent
        case "waitforagents":     self = .waitForAgents
        case "queryagent":        self = .queryAgent
        case "notifyapp":         self = .notifyApp
        case "manageautomations": self = .manageAutomations
        default:                  self = .other(toolName)
        }
    }
}
