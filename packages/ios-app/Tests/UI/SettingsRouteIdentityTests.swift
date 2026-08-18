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
}
