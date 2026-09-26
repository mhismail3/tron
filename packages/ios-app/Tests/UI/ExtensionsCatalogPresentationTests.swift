import Testing
@testable import TronMobile

/// Failure modes: a Gateway module list this client cannot decode would leave
/// the Tron Modules container empty, and a themes projection that still read
/// every resolved category would put skills and prompts back into a sheet the
/// plan removed them from.
@Suite("Extensions sheet containers")
struct ExtensionsCatalogPresentationTests {

    @Test("modules.list decodes the module rows and MCP tool sources")
    func moduleListDecoding() throws {
        let value: JSONValue = .object([
            "modules": .array([.object([
                "name": .string("tron-core"),
                "purpose": .string("Tron core extension"),
                "tools": .array([.string("knowledge"), .string("connections"), .string("jev")]),
                "commands": .array([]),
            ])]),
            "connections": .array([.object([
                "id": .string("mcp-1"), "definitionId": .string("mcp.remote-http"), "health": .string("ready"),
            ])]),
        ])
        let list = try value.decode(TronModuleList.self)
        #expect(list.modules.map(\.name) == ["tron-core"])
        #expect(list.modules.first?.purpose == "Tron core extension")
        #expect(list.modules.first?.tools == ["knowledge", "connections", "jev"])
        // No Tron module registers a command today; an empty list stays empty.
        #expect(list.modules.first?.commands.isEmpty == true)
        #expect(list.connections.map(\.id) == ["mcp-1"])
        #expect(IntegrationHealthPresentation.label(list.connections[0].health) == "Ready")
        #expect(IntegrationHealthPresentation.label("setup-required") == "Setup required")
    }

    @Test("only resolved themes are presented, so skills and prompts cannot reappear here")
    func themesOnly() {
        let resources: JSONValue = .object([
            "extensions": .array([]),
            "skills": .array([.object([
                "path": .string("/skills/repo-optimizer/SKILL.md"),
                "enabled": .bool(true),
                "metadata": .object(["source": .string("auto"), "scope": .string("user")]),
            ])]),
            "prompts": .array([.object([
                "path": .string("/prompts/robust-change.md"),
                "enabled": .bool(true),
                "metadata": .object(["source": .string("local"), "scope": .string("user")]),
            ])]),
            "themes": .array([
                .object([
                    "path": .string("/themes/terminal-dark.json"),
                    "enabled": .bool(true),
                    "metadata": .object(["source": .string("npm:pi-themes"), "scope": .string("user")]),
                ]),
                .object([
                    "path": .string("/themes/old.json"),
                    "enabled": .bool(false),
                    "metadata": .object(["source": .string("auto"), "scope": .string("project")]),
                ]),
            ]),
        ])
        let items = PackageThemesPresentation.items(from: resources)
        #expect(items.map(\.displayName) == ["Terminal Dark", "Old"])
        #expect(items.map(\.statusDescription) == ["Ready to use", "Turned off"])
        #expect(items.map(\.path) == ["/themes/terminal-dark.json", "/themes/old.json"])
        #expect(items.map(\.sourceDescription) == ["From npm:pi-themes", "Discovered automatically"])
        #expect(PackageThemesPresentation.summary(for: items) == "1 ready · 1 turned off")
        // Mixed sources and scopes defer to the technical projection.
        #expect(PackageThemesPresentation.caption(for: items) == "Source and scope details are available in Technical Details.")
        #expect(PackageThemesPresentation.items(from: .object([:])).isEmpty)
        #expect(PackageThemesPresentation.caption(for: []) == nil)
    }

    @Test("a shared theme source and scope are stated once")
    func sharedThemeProvenance() {
        let resources: JSONValue = .object(["themes": .array([
            .object([
                "path": .string("/themes/a.json"), "enabled": .bool(true),
                "metadata": .object(["source": .string("npm:pi-themes"), "scope": .string("user")]),
            ]),
            .object([
                "path": .string("/themes/b.json"), "enabled": .bool(true),
                "metadata": .object(["source": .string("npm:pi-themes"), "scope": .string("user")]),
            ]),
        ])])
        let items = PackageThemesPresentation.items(from: resources)
        #expect(PackageThemesPresentation.hasSharedSource(items))
        #expect(PackageThemesPresentation.summary(for: items) == "2 ready to use")
        #expect(PackageThemesPresentation.caption(for: items) == "From npm:pi-themes · Available in every project.")
    }
}
