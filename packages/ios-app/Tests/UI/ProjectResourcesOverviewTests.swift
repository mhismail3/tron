import Testing
@testable import TronMobile

/// Failure modes these tests target, from the R-0 audit of the resources
/// organization: a duplicated or missing group after the Extensions section is
/// removed; Pi's `origin` mistaken for the new distribution tag; prompt/skill
/// commands duplicated into the Commands group; and a fail-soft subagent
/// projection rendering as an unexplained empty group.
@Suite("Project resources overview")
struct ProjectResourcesOverviewTests {

    /// Gateway-shaped `session.resources` fixture.
    private var resources: JSONValue {
        .object([
            "commands": .array([
                .object([
                    "name": .string("tron:review"),
                    "description": .string("Review the working tree"),
                    "source": .string("extension"),
                    "sourcePath": .string("/extensions/review.ts"),
                    "resourceSource": .string("inline"),
                    "resourceScope": .string("temporary"),
                    "distribution": .string("module"),
                ]),
                .object([
                    "name": .string("robust-change"),
                    "source": .string("prompt"),
                    "resourceScope": .string("user"),
                    "resourceOrigin": .string("top-level"),
                    "distribution": .string("local"),
                ]),
                .object([
                    "name": .string("skill:repo-optimizer"),
                    "source": .string("skill"),
                ]),
            ]),
            "tools": .array([
                .object([
                    "name": .string("read"),
                    "description": .string("Read a file"),
                    "scope": .string("user"),
                    "source": .string("builtin"),
                ]),
                .object([
                    "name": .string("subagent"),
                    "scope": .string("user"),
                    "source": .string("npm:pi-subagents@0.59.0"),
                    "origin": .string("package"),
                    "distribution": .string("external"),
                ]),
            ]),
            "skills": .object([
                "skills": .array([
                    .object([
                        "name": .string("repo-optimizer"),
                        "description": .string("Optimize the repository"),
                        "path": .string("/skills/repo-optimizer/SKILL.md"),
                        "scope": .string("user"),
                        "source": .string("auto"),
                        "distribution": .string("local"),
                    ]),
                ]),
                "diagnostics": .array([.object(["path": .string("/skills/broken"), "error": .string("unreadable")])]),
            ]),
            "prompts": .object([
                "prompts": .array([
                    .object([
                        "name": .string("robust-change"),
                        "path": .string("/prompts/robust-change.md"),
                        "scope": .string("user"),
                        "source": .string("local"),
                        "origin": .string("top-level"),
                        "distribution": .string("local"),
                    ]),
                ]),
                "diagnostics": .array([]),
            ]),
            "extensions": .array([
                .object(["name": .string("local-tools.ts"), "path": .string("/project/.pi/extensions/local-tools.ts"), "tools": .array([.string("echo")])]),
            ]),
            "extensionLoadErrors": .array([]),
            "subagents": .array([
                .object([
                    "name": .string("deepseek-worker"),
                    "description": .string("Implementation subagent"),
                    "model": .string("openai-codex/gpt-6-luna"),
                    "thinking": .string("high"),
                    "source": .string("user"),
                    "distribution": .string("local"),
                ]),
                .object([
                    "name": .string("worker"),
                    "source": .string("builtin"),
                    "distribution": .string("external"),
                ]),
            ]),
            "contextFiles": .array([.object(["name": .string("AGENTS.md"), "path": .string("/AGENTS.md")])]),
        ])
    }

    @Test("the overview groups every available resource once, in plan order")
    func groupOrderAndCompleteness() {
        let content = ProjectResourceOverviewPresentation.content(from: resources)
        #expect(content.sections.map(\.kind) == [.skills, .prompts, .commands, .tools, .subagents])
        #expect(content.sections.map(\.kind.rawValue) == ["Skills", "Prompts", "Commands", "Tools", "Subagents"])
        // The Extensions section left this sheet; its wire field stays decoded
        // by the Hooks views, and no group may claim those rows here.
        #expect(!content.sections.contains { $0.kind.key == "extensions" })
        let counts = Dictionary(uniqueKeysWithValues: content.sections.map { ($0.kind, $0.rows.count) })
        #expect(counts == [.skills: 1, .prompts: 1, .commands: 1, .tools: 2, .subagents: 2])
    }

    @Test("only extension commands appear in the Commands group")
    func commandFilter() {
        let commands = ProjectResourceOverviewPresentation.rows(kind: .commands, root: resources.objectValue ?? [:])
        #expect(commands.map(\.title) == ["Tron Review"])
        // Prompt- and skill-sourced commands stay in their own groups only.
        #expect(commands.allSatisfy { $0.value.objectValue?["source"]?.stringValue == "extension" })
        let prompts = ProjectResourceOverviewPresentation.rows(kind: .prompts, root: resources.objectValue ?? [:])
        let skills = ProjectResourceOverviewPresentation.rows(kind: .skills, root: resources.objectValue ?? [:])
        #expect(prompts.map(\.title) == ["Robust Change"])
        #expect(skills.map(\.title) == ["Repo Optimizer"])
    }

    @Test("distribution comes from the new field, never from Pi's origin")
    func distributionIsNotOrigin() {
        let content = ProjectResourceOverviewPresentation.content(from: resources)
        let rows = content.sections.flatMap(\.rows)
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0) })
        #expect(byTitle["Subagent"]?.distribution == .external)
        #expect(byTitle["Repo Optimizer"]?.distribution == .local)
        #expect(byTitle["Robust Change"]?.distribution == .local)
        #expect(byTitle["Tron Review"]?.distribution == .module)
        // Pi built-ins carry no distribution and keep no tag.
        #expect(byTitle["Read File"]?.distribution == nil)
        // A local top-level resource keeps Pi's origin on the scope badge while
        // its distribution stays local.
        #expect(byTitle["Robust Change"]?.resourceOrigin == .topLevel)
        #expect(byTitle["Subagent"]?.resourceOrigin == .package)
    }

    @Test("unknown or malformed distribution values render no tag")
    func unknownDistribution() {
        let value: JSONValue = .object([
            "tools": .array([
                .object(["name": .string("echo"), "distribution": .string("builtin")]),
                .object(["name": .string("other"), "distribution": .number(3)]),
            ]),
        ])
        let rows = ProjectResourceOverviewPresentation.rows(kind: .tools, root: value.objectValue ?? [:])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.distribution == nil })
    }

    @Test("subagent rows name their description and pinned model, and a failed catalog is explained")
    func subagents() {
        let content = ProjectResourceOverviewPresentation.content(from: resources)
        let subagents = content.sections.first { $0.kind == .subagents }?.rows ?? []
        #expect(subagents.map(\.title) == ["Deepseek Worker", "Worker"])
        #expect(subagents.first?.subtitle == "Implementation subagent · Model openai-codex/gpt-6-luna")
        #expect(subagents.last?.subtitle == nil)
        #expect(content.subagentDiagnostic == nil)

        let unavailable = ProjectResourceOverviewPresentation.content(from: .object([
            "subagents": .array([]),
            "subagentDiagnostics": .string("subagent catalog unavailable: package missing"),
        ]))
        #expect(unavailable.sections.first { $0.kind == .subagents }?.rows.isEmpty == true)
        #expect(unavailable.subagentDiagnostic == "subagent catalog unavailable: package missing")
    }

    @Test("skill and prompt diagnostics still reach the Diagnostics group")
    func diagnosticsRetained() {
        let content = ProjectResourceOverviewPresentation.content(from: resources)
        #expect(content.diagnostics.arrayValue?.count == 1)
        #expect(ProjectResourceOverviewPresentation.content(from: nil) == .empty)
    }

    @Test("the distribution tag maps every value to its plan label")
    func tagLabels() {
        #expect(ResourceDistributionTag.title(for: .external) == "External")
        #expect(ResourceDistributionTag.title(for: .module) == "Module")
        #expect(ResourceDistributionTag.title(for: .local) == "Local")
        #expect(ResourceDistributionTag.title(for: nil) == nil)
    }

    @Test("Gateway-shaped command JSON decodes Pi's resource origin on both command models")
    func commandDecoding() throws {
        let command = try resources.objectValue?["commands"]?.arrayValue?[0].decode(CommandInfo.self)
        #expect(command?.resourceOrigin == nil)
        let prompt = try resources.objectValue?["commands"]?.arrayValue?[1].decode(CommandInfo.self)
        #expect(prompt?.resourceOrigin == .topLevel)

        // The wire carries `distribution` for command rows; the sheet reads it
        // from the raw projection, so the command models decode without it.
        let detail = try JSONValue.object([
            "name": .string("subagent"),
            "source": .string("extension"),
            "resourceOrigin": .string("package"),
            "distribution": .string("external"),
            "content": .string("body"),
        ]).decode(CommandResourceDetail.self)
        #expect(detail.resourceOrigin == .package)
        #expect(detail.content == "body")
        let legacy = try JSONValue.object([
            "name": .string("subagent"),
            "source": .string("extension"),
        ]).decode(CommandResourceDetail.self)
        #expect(legacy.resourceOrigin == nil)
    }
}
