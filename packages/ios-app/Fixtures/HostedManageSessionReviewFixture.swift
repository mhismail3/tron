#if HOSTED_TEST
import Foundation
import TronMobileCore

enum HostedManageSessionReview {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-manage-session-review")

    static var contextUsage: ContextUsage? {
        guard enabled else { return nil }
        return try? JSONDecoder.gateway.decode(ContextUsage.self, from: Data(#"{"tokens":311000,"contextWindow":1000000,"percent":31.1}"#.utf8))
    }

    static func handles(_ method: String) -> Bool {
        ["session.commandDetail", "session.subagentDetail", "session.workspace.inspect",
         "git.inspect", "trust.inspect"].contains(method)
    }

    static let commandBody = (["import type { ExtensionAPI } from \"@earendil-works/pi-coding-agent\";", "",
        "export default function review(pi: ExtensionAPI) {",
        "  pi.registerCommand(\"review\", {",
        "    description: \"Review the working tree before landing\",",
        "    handler: async (args, ctx) => {"]
        + (1...24).map { "      await ctx.step(\($0), \"Check \($0) of the review list\");" }
        + ["      ctx.ui.notify(\"Review complete\");", "    },", "  });", "}", "// END OF REVIEW COMMAND"]).joined(separator: "\n")

    static let subagentBody = (["You are a fast codebase scout. Return compressed context for a handoff.", "",
        "## Method", ""]
        + (1...18).map { "\($0). Read the files the task names, then follow imports one level (\($0))." }
        + ["", "## Output", "", "A short list of paths, symbols and risks.", "", "END OF SCOUT DEFINITION"]).joined(separator: "\n")

    static func response(_ method: String, params: [String: JSONValue]) -> JSONValue {
        switch method {
        case "session.commandDetail":
            return .object(["name": params["name"] ?? .string("review"), "description": .string("Review the working tree before landing"),
                "source": .string("extension"), "sourcePath": .string("/Users/fixture/.tron/agent/extensions/review.ts"),
                "resourceSource": .string("local"), "resourceScope": .string("user"), "resourceOrigin": .string("top-level"),
                "content": .string(commandBody), "contentBytes": .number(Double(commandBody.utf8.count)), "contentTruncated": .bool(false)])
        case "session.subagentDetail":
            return .object(["name": params["name"] ?? .string("scout"), "description": .string("Fast codebase recon"),
                "source": .string("user"), "distribution": .string("local"),
                "content": .string(subagentBody), "contentBytes": .number(Double(subagentBody.utf8.count)), "contentTruncated": .bool(false)])
        case "session.workspace.inspect":
            return .object(["root": .string("/workspace"), "revision": .string("fixture-revision"),
                "repository": .object(["root": .string("/workspace"), "branch": .string("main"), "head": .string("0123456789abcdef"),
                    "detached": .bool(false), "unborn": .bool(false), "dirty": .bool(false), "changes": .array([])])])
        case "git.inspect":
            return .object(["isRepository": .bool(true), "branch": .string("main"), "dirty": .bool(false),
                "branches": .array([.object(["name": .string("main"), "checkedOut": .bool(true)])]), "commits": .array([])])
        case "trust.inspect":
            return .object(["requiresDecision": .bool(false), "effectiveDecision": .bool(true)])
        default:
            return .null
        }
    }
}
#endif
