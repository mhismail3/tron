import Foundation

// MARK: - Bash Details Helper

/// Extracts Phase 2 metadata from tool details (server-side audit data).
/// Used by BashToolDetailSheet to display shell, interactive, env, ptyInput info.
enum BashDetailsHelper {

    /// Extract exit code from details JSON (more reliable than regex from result text).
    static func exitCode(from details: [String: AnyCodable]?) -> Int? {
        guard let details else { return nil }
        if let code = details["exitCode"]?.value as? Int {
            return code
        }
        if let code = details["exitCode"]?.value as? Double {
            return Int(code)
        }
        return nil
    }

    /// Extract shell from details (only set when non-bash).
    static func shell(from details: [String: AnyCodable]?) -> String? {
        details?["shell"]?.value as? String
    }

    /// Extract interactive flag from details.
    static func isInteractive(from details: [String: AnyCodable]?) -> Bool {
        details?["interactive"]?.value as? Bool ?? false
    }

    /// Extract ptyInput audit log from details.
    static func ptyInput(from details: [String: AnyCodable]?) -> [[String: String]]? {
        guard let arr = details?["ptyInput"]?.value as? [[String: Any]] else { return nil }
        return arr.map { obj in
            var result: [String: String] = [:]
            for (k, v) in obj {
                if let s = v as? String {
                    result[k] = s
                }
            }
            return result
        }
    }

    /// Determine sandbox mode from arguments.
    /// Returns nil (no sandbox), "lightweight", or "docker".
    static func sandboxMode(from args: String) -> String? {
        if let sandboxStr = ToolArgumentParser.string("sandbox", from: args) {
            // "docker" stays as-is; "true" (LLM quirk) maps to "lightweight"
            return sandboxStr == "true" ? "lightweight" : sandboxStr
        }
        if ToolArgumentParser.boolean("sandbox", from: args) == true {
            return "lightweight"
        }
        return nil
    }

    /// Redact ptyInput send values for sensitive prompts (password, secret, token, passphrase).
    static func redactPtyInput(_ pairs: [[String: String]]) -> [[String: String]] {
        pairs.map { pair in
            let wait = pair["wait"] ?? ""
            let send = pair["send"] ?? ""
            let lower = wait.lowercased()
            let isSensitive = lower.contains("password")
                || lower.contains("passphrase")
                || lower.contains("secret")
                || lower.contains("token")
            return [
                "wait": wait,
                "send": isSensitive ? "[REDACTED]" : send,
            ]
        }
    }
}

// MARK: - Bash Summary Helper

/// Generates chip summary text for Bash tool calls, incorporating Phase 2 context.
enum BashSummaryHelper {

    /// Generate the chip summary for a Bash tool call.
    /// Shows shell/interactive/sandbox prefix before the truncated command.
    static func summary(from args: String) -> String {
        let command = ToolArgumentParser.command(from: args)
        var prefix = ""

        // Sandbox prefix
        if let sandbox = BashDetailsHelper.sandboxMode(from: args) {
            prefix = sandbox == "docker" ? "docker: " : "sandbox: "
        }

        // Interactive/PTY prefix
        if ToolArgumentParser.boolean("interactive", from: args) == true {
            prefix = "PTY: " + prefix
        }

        // Shell prefix (only for non-bash)
        if let shell = ToolArgumentParser.string("shell", from: args),
           shell != "bash" {
            prefix = "\(shell): " + prefix
        }

        let full = prefix + command
        return ToolArgumentParser.truncate(full)
    }
}
