import SwiftUI
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

/// Failure modes for the per-package Provides sheet: `provides` required instead
/// of optional would fail the whole package read on an older Gateway; groups
/// rendered out of plan order, or kept alive while empty, would show resources a
/// package does not provide; a group styled from its own copy of the Project
/// Resources colours could drift from that sheet; and a resolved theme that only
/// the deleted sheet-level list showed would leave the app once that list went.
@Suite("Extensions package detail")
struct PackageDetailPresentationTests {
    /// One theme a package owns by the same evidence the Gateway attributes
    /// `provides` with (Pi's `origin: package` plus the package's source and
    /// scope), one discovered theme, and one theme whose package is gone.
    private var resources: JSONValue {
        .object([
            "themes": .array([
                .object([
                    "path": .string("/packages/pi-themes/themes/terminal-dark.json"),
                    "enabled": .bool(true),
                    "metadata": .object([
                        "source": .string("npm:pi-themes"),
                        "scope": .string("user"),
                        "origin": .string("package"),
                    ]),
                ]),
                .object([
                    "path": .string("/agent/themes/mine.json"),
                    "enabled": .bool(true),
                    "metadata": .object([
                        "source": .string("auto"),
                        "scope": .string("user"),
                        "origin": .string("top-level"),
                    ]),
                ]),
                .object([
                    "path": .string("/packages/removed/themes/legacy.json"),
                    "enabled": .bool(true),
                    "metadata": .object([
                        "source": .string("npm:removed-package"),
                        "scope": .string("user"),
                        "origin": .string("package"),
                    ]),
                ]),
            ]),
        ])
    }

    private func decodedPackage(provides: JSONValue?) throws -> PackageSummary {
        var object: [String: JSONValue] = [
            "source": .string("npm:pi-themes"),
            "scope": .string("user"),
            "filtered": .bool(false),
            "installedPath": .string("/packages/pi-themes"),
        ]
        if let provides { object["provides"] = provides }
        return try JSONValue.object(object).decode(PackageSummary.self)
    }

    private var everyKind: JSONValue {
        .object([
            "skills": .array([.string("repo-optimizer")]),
            "prompts": .array([.string("robust-change")]),
            "themes": .array([.string("terminal-dark")]),
            "subagents": .array([.string("explorer")]),
            "tools": .array([.string("subagent")]),
            "commands": .array([.string("goal")]),
        ])
    }

    @Test("provides decodes every kind and stays optional for an older Gateway")
    func providesDecoding() throws {
        let package = try decodedPackage(provides: everyKind)
        #expect(package.provides?.skills == ["repo-optimizer"])
        #expect(package.provides?.prompts == ["robust-change"])
        #expect(package.provides?.themes == ["terminal-dark"])
        #expect(package.provides?.subagents == ["explorer"])
        #expect(package.provides?.tools == ["subagent"])
        #expect(package.provides?.commands == ["goal"])

        // A Gateway that predates `provides` still decodes its package listing.
        let legacy = try decodedPackage(provides: nil)
        #expect(legacy.provides == nil)
        #expect(legacy.source == "npm:pi-themes")

        let emptyResources = JSONValue.object([
            "extensions": .array([]), "skills": .array([]),
            "prompts": .array([]), "themes": .array([]),
        ])
        let listing = try JSONValue.object([
            "packages": .array([.object([
                "source": .string("npm:pi-themes"),
                "scope": .string("user"),
                "filtered": .bool(false),
                "provides": everyKind,
            ])]),
            "resources": emptyResources,
            "providesDiagnostic": .string("tools and commands are unavailable: boom"),
        ]).decode(PackageInventory.self)
        #expect(listing.packages.first?.provides?.tools == ["subagent"])
        #expect(listing.providesDiagnostic == "tools and commands are unavailable: boom")

        let withoutDiagnostic = try JSONValue.object([
            "packages": .array([]),
            "resources": emptyResources,
        ]).decode(PackageInventory.self)
        #expect(withoutDiagnostic.providesDiagnostic == nil)
    }

    @Test("Provides groups keep plan order and hide every empty kind")
    func groupOrderAndEmptyHiding() {
        #expect(PackageProvidesKind.allCases.map(\.rawValue) ==
            ["Skills", "Prompts", "Subagents", "Tools", "Commands", "Themes"])

        let provides = PackageProvides(
            skills: ["repo-optimizer"],
            prompts: [],
            themes: ["terminal-dark"],
            subagents: [],
            tools: ["subagent"],
            commands: []
        )
        let content = PackageProvidesPresentation.content(from: provides)
        #expect(content.groups.map(\.kind) == [.skills, .tools, .themes])
        #expect(content.groups.map(\.names) == [["repo-optimizer"], ["subagent"], ["terminal-dark"]])
        #expect(content.reported)
        #expect(content.isEmpty == false)

        let nothing = PackageProvidesPresentation.content(from: PackageProvides(
            skills: [], prompts: [], themes: [], subagents: [], tools: [], commands: []
        ))
        #expect(nothing.groups.isEmpty)
        #expect(nothing.isEmpty)

        // An absent field is not an empty package: no groups, and no
        // "provides no agent resources" line either.
        let absent = PackageProvidesPresentation.content(from: nil)
        #expect(absent.groups.isEmpty)
        #expect(absent.reported == false)
        #expect(absent.isEmpty == false)
    }

    @MainActor
    @Test("every Provides group reuses the Project Resources icon and colour for its kind")
    func groupPresentation() {
        #expect(PackageProvidesKind.skills.projectResourceKind == .skills)
        #expect(PackageProvidesKind.prompts.projectResourceKind == .prompts)
        #expect(PackageProvidesKind.subagents.projectResourceKind == .subagents)
        #expect(PackageProvidesKind.tools.projectResourceKind == .tools)
        #expect(PackageProvidesKind.commands.projectResourceKind == .commands)
        #expect(PackageProvidesKind.themes.projectResourceKind == nil)
        for kind in PackageProvidesKind.allCases {
            guard let project = kind.projectResourceKind else { continue }
            #expect(kind.icon == project.icon)
            #expect(kind.accent == project.accent)
        }
        // Themes have no Project Resources kind; they keep the terminal-theme
        // icon and colour Locations and Extensions already use for them.
        #expect(PackageProvidesKind.themes.icon == "paintpalette")
        #expect(PackageProvidesKind.themes.accent == .tronTeal)
    }

    @Test("a packaged theme stays reachable through its own package")
    func packagedThemeReachability() throws {
        let package = try decodedPackage(provides: everyKind)
        let groups = PackageProvidesPresentation.content(from: package.provides).groups
        #expect(groups.first { $0.kind == .themes }?.names == ["terminal-dark"])
        // The theme's own package detail sheet lists it; the Local themes group
        // must not claim a theme an installed package owns.
        #expect(PackageThemesPresentation.localItems(from: resources, packages: [package])
            .map(\.path) == ["/agent/themes/mine.json", "/packages/removed/themes/legacy.json"])
    }

    @Test("Local themes appear only while some exist, and never lose an orphan")
    func localThemes() throws {
        let owner = try decodedPackage(provides: everyKind)
        let local = PackageThemesPresentation.localItems(from: resources, packages: [owner])
        #expect(local.map(\.displayName) == ["Mine", "Legacy"])
        // A theme whose package is no longer installed has no detail sheet to
        // appear in, so it stays in the Local themes group rather than vanishing.
        #expect(PackageThemesPresentation.localItems(from: resources, packages: []).count == 3)

        let packagedOnly = JSONValue.object(["themes": .array([
            .object([
                "path": .string("/packages/pi-themes/themes/terminal-dark.json"),
                "enabled": .bool(true),
                "metadata": .object([
                    "source": .string("npm:pi-themes"),
                    "scope": .string("user"),
                    "origin": .string("package"),
                ]),
            ]),
        ])])
        #expect(PackageThemesPresentation.localItems(from: packagedOnly, packages: [owner]).isEmpty)
    }
}
