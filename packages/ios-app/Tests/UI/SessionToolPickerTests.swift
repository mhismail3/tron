import Testing
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes: Pi sends `namespace` as an object, and reading it as a string
/// put every tool in one group; hidden tools must never be offered; MCP tools
/// must group by server with their server prefix removed; package tools must
/// group under a readable package name.
@Suite("Available Tools grouping")
struct SessionToolPickerTests {
    static let resources: JSONValue = .object(["tools": .array([
        .object(["name": .string("read"), "exposure": .string("direct"), "source": .string("builtin"), "description": .string("Read the contents of a file.")]),
        .object(["name": .string("codemode"), "exposure": .string("model-only"), "source": .string("builtin")]),
        .object(["name": .string("display"), "exposure": .string("direct"), "source": .string("inline"), "distribution": .string("module")]),
        .object(["name": .string("subagent"), "label": .string("Subagent"), "exposure": .string("direct"), "source": .string("npm:pi-subagents@0.59.0"), "distribution": .string("external")]),
        .object(["name": .string("agent_browser"), "exposure": .string("direct"), "source": .string("git:github.com/example/pi-agent-browser-native@d6cde09"), "distribution": .string("external")]),
        .object(["name": .string("mcp__deepwiki__ask_question"), "label": .string("mcp__deepwiki__ask_question"), "exposure": .string("codemode"), "source": .string("builtin"),
                 "namespace": .object(["name": .string("mcp__deepwiki"), "description": .string("DeepWiki")])]),
        .object(["name": .string("mcp__deepwiki__secret"), "exposure": .string("hidden"), "source": .string("builtin"),
                 "namespace": .object(["name": .string("mcp__deepwiki")])]),
    ])])

    @Test("groups by origin from the real wire shape, in a stable order")
    func groupsByOrigin() {
        let groups = AvailableToolsPresentation.groups(from: Self.resources)
        #expect(groups.map(\.title) == ["Built-in", "Tron", "pi-agent-browser-native", "pi-subagents", "deepwiki (MCP)"])
        #expect(groups.first?.tools.map(\.name) == ["codemode", "read"])
        let mcp = groups.last
        #expect(mcp?.tools.map(\.name) == ["mcp__deepwiki__ask_question"], "hidden tools are never offered")
        #expect(mcp?.tools.first?.title.contains("mcp__") == false)
    }

    @Test("active names come from the session context")
    func activeNames() {
        let context: JSONValue = .object(["activeTools": .array([.string("read"), .string("subagent")])])
        #expect(AvailableToolsPresentation.activeNames(from: context) == ["read", "subagent"])
    }
}
