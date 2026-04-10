import Foundation

// MARK: - Computer Use Details Helper

/// Extracts metadata from ComputerUse tool details and arguments.
/// Used by ComputerUseToolDetailSheet to display action info.
enum ComputerUseDetailsHelper {

    /// Actions that modify system state.
    static let mutatingActions: Set<String> = [
        "click", "type", "keypress", "scroll", "moveMouse"
    ]

    /// Extract action name from details JSON.
    static func action(from details: [String: AnyCodable]?) -> String? {
        details?.string("action")
    }

    /// Extract x coordinate from details.
    static func x(from details: [String: AnyCodable]?) -> Double? {
        details?.double("x")
    }

    /// Extract y coordinate from details.
    static func y(from details: [String: AnyCodable]?) -> Double? {
        details?.double("y")
    }

    /// Extract click count from details.
    static func clicks(from details: [String: AnyCodable]?) -> Int? {
        details?.int("clicks")
    }

    /// Extract typed text length from details.
    static func textLength(from details: [String: AnyCodable]?) -> Int? {
        details?.int("length")
    }

    /// Extract keys array from details.
    static func keys(from details: [String: AnyCodable]?) -> [String]? {
        details?.stringArray("keys")
    }

    /// Extract scroll direction from details.
    static func direction(from details: [String: AnyCodable]?) -> String? {
        details?.string("direction")
    }

    /// Extract scroll amount from details.
    static func amount(from details: [String: AnyCodable]?) -> Int? {
        details?.int("amount")
    }

    /// Extract window name from details.
    static func window(from details: [String: AnyCodable]?) -> String? {
        details?.string("window")
    }

    /// Extract screenshot size in bytes from details.
    static func sizeBytes(from details: [String: AnyCodable]?) -> Int? {
        details?.int("sizeBytes")
    }

    /// Whether a fallback method was used (e.g., keyboard scroll fallback).
    static func isFallback(from details: [String: AnyCodable]?) -> Bool {
        details?.bool("fallback") ?? false
    }

    /// Check if action is mutating.
    static func isMutating(_ action: String) -> Bool {
        mutatingActions.contains(action)
    }

    /// Format coordinates as "(x, y)" string.
    static func formatCoordinates(x: Double, y: Double) -> String {
        if x == x.rounded() && y == y.rounded() {
            return "(\(Int(x)), \(Int(y)))"
        }
        return "(\(String(format: "%.1f", x)), \(String(format: "%.1f", y)))"
    }

    /// Format a key combination (e.g., ["cmd", "c"] → "Cmd+C").
    static func formatKeys(_ keys: [String]) -> String {
        keys.map { key in
            switch key.lowercased() {
            case "cmd", "command": return "Cmd"
            case "ctrl", "control": return "Ctrl"
            case "alt", "option": return "Opt"
            case "shift": return "Shift"
            case "enter", "return": return "Return"
            case "escape", "esc": return "Esc"
            case "space": return "Space"
            case "tab": return "Tab"
            case "delete", "backspace": return "Delete"
            case "up": return "↑"
            case "down": return "↓"
            case "left": return "←"
            case "right": return "→"
            default: return key.uppercased()
            }
        }.joined(separator: "+")
    }
}

// MARK: - Computer Use Summary Helper

/// Generates chip summary text for ComputerUse tool calls.
enum ComputerUseSummaryHelper {

    /// Extract a coordinate value as a display string.
    /// Handles both integer and string JSON values.
    private static func coordString(_ key: String, from args: String) -> String {
        if let v = ToolArgumentParser.integer(key, from: args) {
            return "\(v)"
        }
        return ToolArgumentParser.string(key, from: args) ?? "?"
    }

    /// Generate the chip summary for a ComputerUse tool call.
    static func summary(from args: String) -> String {
        let action = ToolArgumentParser.action(from: args)
        guard !action.isEmpty else { return "" }

        switch action {
        case "screenshot":
            if let window = ToolArgumentParser.string("window", from: args) {
                return "screenshot: \(ToolArgumentParser.truncate(window, maxLength: 25))"
            }
            return "screenshot"

        case "click":
            let x = coordString("x", from: args)
            let y = coordString("y", from: args)
            let clicks = ToolArgumentParser.integer("clicks", from: args) ?? 1
            let prefix = clicks > 1 ? "double-click" : "click"
            return "\(prefix) (\(x), \(y))"

        case "type":
            if let text = ToolArgumentParser.string("text", from: args) {
                return "type: \"\(ToolArgumentParser.truncate(text, maxLength: 25))\""
            }
            return "type"

        case "keypress":
            if let keys = ToolArgumentParser.stringArray("keys", from: args) {
                return ComputerUseDetailsHelper.formatKeys(keys)
            }
            return "keypress"

        case "scroll":
            let dir = ToolArgumentParser.string("direction", from: args) ?? "down"
            return "scroll \(dir)"

        case "getWindows":
            return "list windows"

        case "focusWindow":
            if let window = ToolArgumentParser.string("window", from: args) {
                return "focus: \(ToolArgumentParser.truncate(window, maxLength: 25))"
            }
            return "focus window"

        case "moveMouse":
            let x = coordString("x", from: args)
            let y = coordString("y", from: args)
            return "move to (\(x), \(y))"

        default:
            return action
        }
    }
}
