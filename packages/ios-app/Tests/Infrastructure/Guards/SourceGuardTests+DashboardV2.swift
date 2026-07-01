import Testing
import Foundation

extension SourceGuardTests {
    @Test("Dashboard 2.0 owns its chrome and sheet lab")
    func dashboardV2OwnsChromeAndSheetLab() throws {
        let iosRoot = iosAppRoot()
        let content = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/ContentView.swift"
        )
        let sidebar = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/SessionSidebar.swift"
        )
        let shellToolbar = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/ShellToolbarContent.swift"
        )
        let dashboard = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/DashboardV2View.swift"
        )
        let components = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/DashboardV2Components.swift"
        )
        let labSheet = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/DashboardV2LabSheet.swift"
        )
        let chatToolbar = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Chat/Shell/ChatView+Toolbar.swift"
        )
        let sheetComponents = try dashboardV2Source(
            at: iosRoot,
            "Sources/UI/Components/SheetComponents.swift"
        )

        #expect(content.contains("@State private var dashboardMode: DashboardSurfaceMode = .classic"))
        #expect(content.contains("@State private var isDashboardModeMenuPresented = false"))
        #expect(content.contains("DashboardV2View("))
        #expect(content.contains("DashboardModePopupMenu("))
        #expect(!sidebar.contains("DashboardV2"))
        #expect(!sidebar.contains("onDashboardSelector"))
        #expect(sidebar.contains("ShellToolbarContent(title: \"Tron\""))
        #expect(!sidebar.contains("ShellTopBarOverlay"))
        #expect(!shellToolbar.contains("DashboardModeSelector"))
        #expect(!shellToolbar.contains("DashboardV2IconButton("))
        #expect(!shellToolbar.contains("GlassEffectContainer("))
        #expect(!shellToolbar.contains(".glassEffect("))
        #expect(!shellToolbar.contains("TronToolbarIconButton"))
        #expect(shellToolbar.contains("struct ShellToolbarContent: ToolbarContent"))
        #expect(!chatToolbar.contains("DashboardV2"))
        #expect(!chatToolbar.contains("TronToolbarIconButton"))
        #expect(chatToolbar.contains("@ToolbarContentBuilder"))
        #expect(!chatToolbar.contains("leadingTopBarButton"))
        #expect(!sheetComponents.contains("DashboardV2"))
        #expect(!sheetComponents.contains("TronHitTarget"))
        #expect(!sheetComponents.contains("TronToolbarIconButton"))

        #expect(dashboard.contains("ScrollView(.vertical"))
        #expect(dashboard.contains("DashboardV2TopBar("))
        #expect(dashboard.contains("DashboardV2LabOverlay("))
        #expect(dashboard.contains("DashboardV2IconButton("))
        #expect(!dashboard.contains("GlassEffectContainer("))
        #expect(!dashboard.contains("List("))
        #expect(!dashboard.contains("ToolbarItem"))
        #expect(!dashboard.contains(".toolbar {"))

        #expect(components.contains("enum DashboardSurfaceMode"))
        #expect(components.contains("enum DashboardV2Motion"))
        #expect(components.contains("struct DashboardV2IconButton"))
        #expect(components.contains(".buttonStyle(.plain)"))
        #expect(components.contains(".glassEffect("))
        #expect(components.contains(".glassEffectTransition(.materialize)"))
        #expect(components.contains("Circle()"))
        #expect(components.contains("Animation.snappy"))
        #expect(components.contains("Animation.smooth"))

        #expect(labSheet.contains("struct DashboardV2LabOverlay"))
        #expect(labSheet.contains("struct DashboardV2LabSheet"))
        #expect(labSheet.contains("DragGesture(minimumDistance: 16)"))
        #expect(labSheet.contains("dashboard-v2-lab-sheet"))
        #expect(labSheet.contains("DashboardV2Motion.sheetPresent"))
        #expect(!labSheet.contains(".sheet("))
        #expect(!labSheet.contains("GlassEffectContainer("))
        #expect(!labSheet.contains("NavigationStack"))
        #expect(!labSheet.contains("ToolbarItem"))
        #expect(!labSheet.contains(".presentationDetents"))
        #expect(!labSheet.contains(".presentationBackground"))

        #expect(
            !FileManager.default.fileExists(
                atPath: iosRoot.appendingPathComponent("Sources/UI/Components/TronHitTarget.swift").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: iosRoot.appendingPathComponent("UITests/HitTargetContainerUITests.swift").path
            )
        )
    }

    private func dashboardV2Source(at root: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
