#if HOSTED_TEST
import Foundation
import TronMobileCore

/// `-manage-session-review` (#1655): the Manage Session fixture with reported
/// usage, a Git workspace, a trusted project and resources of every kind and
/// source, so its top card, Workspace row, folded Project section, Resources
/// tags and resource bodies render at realistic lengths. Synthetic values only.
enum HostedManageSessionReview {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-manage-session-review")

    static var contextUsage: ContextUsage? {
        guard enabled else { return nil }
        return try? JSONDecoder.gateway.decode(ContextUsage.self, from: Data(#"{"tokens":311000,"contextWindow":1000000,"percent":31.1}"#.utf8))
    }

    static func handles(_ method: String) -> Bool {
        ["session.resources", "session.commandDetail", "session.subagentDetail", "session.workspace.inspect",
         "git.inspect", "trust.inspect"].contains(method)
    }

    /// A command source longer than the preview, so only View All shows its end.
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
            return resources
        }
    }

    private static func row(_ name: String, _ description: String, path: String, scope: String, source: String,
                            distribution: String) -> JSONValue {
        .object(["name": .string(name), "description": .string(description), "path": .string(path), "scope": .string(scope),
                 "source": .string(source), "distribution": .string(distribution)])
    }

    private static var resources: JSONValue {
        .object([
            "tools": .array(HostedSettingsReviewSchema.tools.map {
                .object(["name": .string($0), "description": .string("Session tool details for \($0)."),
                         "parameters": .object(["type": .string("object"), "properties": .object([:])])])
            }),
            "skills": .object(["skills": .array([
                row("tron-ios", "Build, test and inspect iOS artifacts safely.", path: "/Users/fixture/.tron/agent/skills/tron-ios/SKILL.md",
                    scope: "user", source: "auto", distribution: "local"),
                row("repo-notes", "This repository's own conventions.", path: "/workspace/.agents/skills/repo-notes/SKILL.md",
                    scope: "project", source: "auto", distribution: "local"),
                row("pi-subagents", "Delegation guidance from the managed package.", path: "/Users/fixture/.tron/internal/pi-subagents/skills/pi-subagents/SKILL.md",
                    scope: "user", source: "npm:pi-subagents", distribution: "external"),
            ]), "diagnostics": .array([])]),
            "prompts": .object(["prompts": .array([
                row("land", "Fetch, rebase, test and push.", path: "/Users/fixture/.tron/agent/prompts/land.md",
                    scope: "user", source: "auto", distribution: "local"),
            ]), "diagnostics": .array([])]),
            "commands": .array([
                .object(["name": .string("review"), "description": .string("Review the working tree before landing"),
                         "source": .string("extension"), "sourcePath": .string("/Users/fixture/.tron/agent/extensions/review.ts"),
                         "resourceSource": .string("local"), "resourceScope": .string("user"), "resourceOrigin": .string("top-level"),
                         "distribution": .string("local")]),
            ]),
            "subagents": .array([
                .object(["name": .string("scout"), "description": .string("Fast codebase recon"), "source": .string("user"),
                         "distribution": .string("local")]),
                .object(["name": .string("repo-reviewer"), "description": .string("Reviews this repository's diffs"),
                         "source": .string("project"), "distribution": .string("local")]),
                .object(["name": .string("researcher"), "description": .string("Web research brief"), "source": .string("builtin"),
                         "distribution": .string("external")]),
            ]),
        ])
    }
}
#endif
