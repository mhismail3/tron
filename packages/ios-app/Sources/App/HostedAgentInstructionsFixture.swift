#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Deterministic, test-only host for the Agent Instructions sheet. It installs a
/// bounded `instructions` projection in the Gateway's wire shape so the real
/// sheet's sections, sources, and document reader can be driven by XCUITest.
@MainActor
struct HostedAgentInstructionsFixtureView: View {
    @State private var model = AppModel()
    @State private var presented = false

    var body: some View {
        TronPresentationSurface(id: "hosted-agent-instructions-fixture") {
            NavigationStack {
                Text("Agent instructions fixture")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .tronManagedSheet(isPresented: $presented, identity: "hosted.agent-instructions") {
                AgentInstructionsSheet(sessionID: "hosted-agent-instructions-session")
            }
        }
        .environment(model)
        .tronPresentation()
        .preferredColorScheme(.light)
        .task {
            model.installHostedSecondaryProjection(
                context: .object(["instructions": Self.instructions]), tree: [], commands: [], resources: nil
            )
            presented = true
        }
    }

    private static func source(_ fields: [String: String]) -> JSONValue { .object(fields.mapValues { .string($0) }) }

    private static func section(_ id: String, _ text: String, timing: String = "session", source: JSONValue? = nil, entries: [JSONValue]? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "timing": .string(timing), "text": .string(text)]
        if let source { object["source"] = source }
        if let entries { object["entries"] = .array(entries) }
        return .object(object)
    }

    private static func entry(_ fields: [String: String], tools: [String] = [], source: JSONValue) -> JSONValue {
        var object = fields.mapValues { JSONValue.string($0) }
        if !tools.isEmpty { object["tools"] = .array(tools.map { .string($0) }) }
        object["source"] = source
        return .object(object)
    }

    private static let instructions: JSONValue = {
        let pi = source(["kind": "pi"])
        let subagents = source(["kind": "package", "name": "pi-subagents"])
        let agents = "/Users/fixture/Workspace/project/AGENTS.md"
        let skill = "/Users/fixture/Workspace/project/.agents/skills/tron-ios/SKILL.md"
        let tron = "## Tron operating context\nYou are Tron, the user's private agent operating on the Mac.\nRebuilds, restarts, updates, rollbacks, promotions, and deployments of the Gateway hosting this session, or of any Stable or production Gateway, remain manual user actions; never initiate them yourself. A repository's own instructions may permit managing an isolated development Gateway."
        let sections: [JSONValue] = [
            section("preamble", "You are an expert coding assistant operating inside pi, a coding agent harness.", source: pi),
            section("tools", "- read: Read file contents\n- subagent: Delegate to subagents; orchestrate in one workflowScript call.", entries: [
                entry(["name": "read", "text": "Read file contents"], source: pi),
                entry(["name": "subagent", "text": "Delegate to subagents; orchestrate in one workflowScript call."], source: subagents),
                entry(["name": "display", "text": "Proactively display useful visual results in Tron chat."], source: source(["kind": "module", "name": "tron-display"])),
            ]),
            section("rules", "- Use bash for file operations like ls, rg, find\n- Keep one writer per cwd/worktree\n- Be concise in your responses", entries: [
                entry(["text": "Use bash for file operations like ls, rg, find"], source: pi),
                entry(["text": "Keep one writer per cwd/worktree unless writers run in isolated worktrees."], tools: ["subagent"], source: subagents),
                entry(["text": "Be concise in your responses"], source: pi),
            ]),
            section("docs", "Pi documentation (read only when the user asks about pi itself).", source: pi),
            section("project_context", "Project-specific instructions and guidelines:", entries: [
                entry(["name": "AGENTS.md", "path": agents, "text": "# Tron Project Guidelines\n\n## Rules\n\n1. Code, tests, and docs ship together."],
                      source: source(["kind": "file", "path": agents])),
            ]),
            section("skills", "<available_skills/>", entries: [
                entry(["name": "tron-ios", "path": skill, "text": "Build, test, install, inspect, or release-validate Tron iOS artifacts safely."],
                      source: source(["kind": "local", "scope": "project", "path": skill])),
            ]),
            section("cwd", "/Users/fixture/Workspace/project", source: pi),
            section("tron", tron, timing: "turn", source: source(["kind": "module", "name": "tron-core"])),
        ]
        return .object(["text": .string("Fixture full prompt\n\n" + tron), "sections": .array(sections)])
    }()
}
#endif
