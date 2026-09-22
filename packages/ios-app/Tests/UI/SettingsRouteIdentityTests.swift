import Testing
@testable import TronMobile

@MainActor
@Suite("Settings route identity")
struct SettingsRouteIdentityTests {
    @Test("project identity is captured by the presented settings route")
    func projectIdentity() {
        let project = SettingsView(
            scope: .project,
            projectSessionID: "session-a",
            projectCWD: "/workspace/a"
        )
        #expect(project.projectSessionID == "session-a")
        #expect(project.projectCWD == "/workspace/a")

        let dashboard = SettingsView(
            scope: .dashboard,
            projectSessionID: "ignored",
            projectCWD: "/ignored"
        )
        #expect(dashboard.projectSessionID == nil)
        #expect(dashboard.projectCWD == nil)
    }

    @Test("authorized device detail survives a list refresh and adopts refreshed content")
    func authorizedDeviceSelectionSurvivesRefresh() {
        let original = GatewayAuthorizedDevice(
            profileID: "profile-a",
            profileLabel: "Mac",
            device: PairedDevice(id: "device-a", name: "Old name", createdAt: "2025-01-01T00:00:00Z")
        )
        let refreshed = GatewayAuthorizedDevice(
            profileID: "profile-a",
            profileLabel: "Mac",
            device: PairedDevice(id: "device-a", name: "New name", createdAt: "2025-01-01T00:00:00Z")
        )

        #expect(AuthorizedDevicePresentationPolicy.selection(current: original, refreshedDevices: [refreshed]) == refreshed)
        #expect(AuthorizedDevicePresentationPolicy.selection(current: original, refreshedDevices: []) == original)
    }

    @Test("integration routes keep connected services separate from MCP servers")
    func integrationSurfaceFiltering() {
        let service = IntegrationDefinition(
            schemaVersion: 1,
            id: "calendar",
            implementation: "service",
            displayName: "Calendar",
            setupMethods: ["token"],
            capabilities: []
        )
        let mcp = IntegrationDefinition(
            schemaVersion: 1,
            id: "tools",
            implementation: "mcp",
            displayName: "Tools",
            setupMethods: ["local-command"],
            capabilities: []
        )

        #expect(IntegrationsSettingsView.Surface.connectedServices.includes(service))
        #expect(!IntegrationsSettingsView.Surface.connectedServices.includes(mcp))
        #expect(IntegrationsSettingsView.Surface.mcpServers.includes(mcp))
        #expect(!IntegrationsSettingsView.Surface.mcpServers.includes(service))
    }
}
