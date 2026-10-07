import Foundation
import Testing
import TronMobileCore
@testable import TronMobile

@Suite("MCP server list projection")
struct MCPServerListTests {
    @Test("Codemode alias shares the visible choice while preserving stored values until an explicit change")
    func codemodeAliasPresentationAndUpdates() {
        let codemodeChoices = MCPServerPresentationPolicy.exposures.filter { $0.title == "Codemode" }
        #expect(codemodeChoices.map(\.value) == ["codemode"])
        #expect(MCPServerPresentationPolicy.exposureTitle("codemode-deferred") == "Codemode")
        // The menu's selection must be one of its own tags, or the picker shows no
        // choice for a server stored with the alias.
        let offered = MCPServerPresentationPolicy.exposures.map(\.value)
        for stored in ["codemode-deferred"] + offered {
            #expect(offered.contains(MCPServerPresentationPolicy.exposureChoice(stored)))
        }

        let unrelatedFieldUpdate = MCPServerPresentationPolicy.updateFields(server: "example", enabled: false)
        #expect(unrelatedFieldUpdate == ["server": .string("example"), "enabled": .bool(false)])
        let explicitChoice = MCPServerPresentationPolicy.updateFields(server: "example", exposure: codemodeChoices[0].value)
        #expect(explicitChoice == ["server": .string("example"), "exposure": .string("codemode")])
    }

    @Test("decodes the bounded Gateway projection for unhealthy and disabled Pi servers")
    func decodesPinnedCLIReport() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mcp-list-cli.json")
        let data = try Data(contentsOf: fixture)
        let report = try JSONDecoder.gateway.decode(MCPServerList.self, from: data)

        #expect(report.servers.count == 2)
        #expect(report.errors == 0)
        let failed = try #require(report.servers.first { $0.name == "unreachable" })
        #expect(failed.state == "failed")
        #expect(failed.scope == "global")
        #expect(failed.exposure == "codemode")
        #expect(failed.enabled)
        #expect(failed.transport == "http://127.0.0.1:1/mcp")
        #expect(failed.tools.isEmpty)
        #expect(failed.error == "fetch failed")
        #expect(MCPServerPresentationPolicy.stateTitle("needs-auth") == "Needs sign-in")
        #expect(MCPServerPresentationPolicy.isNeedsAuth("needs-auth"))

        let disabled = try #require(report.servers.first { $0.name == "disabled" })
        #expect(disabled.scope == "global")
        #expect(!disabled.enabled)
        #expect(!MCPServerPresentationPolicy.includes(disabled, selectedScope: "project"))
        let project = try JSONValue.object([
            "name": .string("project-server"), "scope": .string("project"),
            "enabled": .bool(true),
            "exposure": .string("direct"), "transport": .string("https://mcp.example.test"),
            "state": .string("connected"), "tools": .array([.string("issues.list")]),
        ]).decode(MCPServerList.Server.self)
        #expect(MCPServerPresentationPolicy.includes(project, selectedScope: "project"))
    }
}
