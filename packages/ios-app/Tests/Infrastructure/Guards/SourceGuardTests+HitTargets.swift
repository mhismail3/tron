import Testing
import Foundation

extension SourceGuardTests {
    @Test("Button-like visual containers use the shared hit-target primitive")
    func buttonLikeVisualContainersUseSharedHitTargetPrimitive() throws {
        let iosRoot = iosAppRoot()
        let hitTargetSource = try source(
            at: iosRoot,
            "Sources/UI/Components/TronHitTarget.swift"
        )

        #expect(hitTargetSource.contains("enum TronHitTargetShape"))
        #expect(hitTargetSource.contains("minimumSize: CGFloat? = nil"))
        #expect(hitTargetSource.contains("func tronHitTarget("))
        #expect(hitTargetSource.contains("struct TronToolbarIconButton: View"))
        #expect(hitTargetSource.contains("struct TronNavigationTopBarOverlay"))
        #expect(hitTargetSource.contains("Circle()"))
        #expect(hitTargetSource.contains("chromeDiameter: CGFloat = 44"))
        #expect(hitTargetSource.contains(".fill(color.opacity(fillOpacity))"))
        #expect(hitTargetSource.contains(".frame(width: diameter, height: diameter)"))
        #expect(hitTargetSource.contains(".background(Rectangle().fill(Color.white.opacity(0.001)))"))
        #expect(hitTargetSource.contains(".contentShape(Rectangle())"))
        #expect(hitTargetSource.contains(".buttonStyle(.plain)"))
        #expect(hitTargetSource.contains("topPadding: CGFloat = 48"))
        #expect(!hitTargetSource.contains("glassOpacity"))
        #expect(!hitTargetSource.contains(".glassEffect("))
        #expect(!hitTargetSource.contains(".onTapGesture"))

        let requiredUsages: [(String, String)] = [
            (
                "Sources/UI/AgentBriefing/AgentBriefingViews.swift",
                ".tronHitTarget(.roundedRectangle(cornerRadius: 12))"
            ),
            (
                "Sources/UI/Chat/Shell/ChatView+Toolbar.swift",
                "TronToolbarIconButton("
            ),
            (
                "Sources/UI/Chat/Shell/ContentView.swift",
                "TronToolbarIconButton("
            ),
            (
                "Sources/UI/Chat/Shell/ShellToolbarContent.swift",
                "TronToolbarIconButton("
            ),
            (
                "Sources/UI/Onboarding/Flow/OnboardingFlowView.swift",
                "TronNavigationTopBarOverlay"
            ),
            (
                "Sources/UI/Onboarding/Steps/PairingStep.swift",
                ".tronHitTarget(.roundedRectangle(cornerRadius: TronSpacing.cornerMD))"
            ),
            (
                "Sources/UI/Chat/Sheets/NewSessionFlowComponents.swift",
                ".tronHitTarget(.roundedRectangle(cornerRadius: 12))"
            ),
            (
                "Sources/UI/Settings/Shell/SettingsPageContainer.swift",
                "TronToolbarIconButton("
            ),
            (
                "Sources/UI/Settings/Shell/SettingsView.swift",
                "TronToolbarIconButton("
            ),
            (
                "Sources/UI/Components/SheetComponents.swift",
                "TronToolbarIconButton("
            ),
            (
                "Sources/UI/Chat/Sheets/ContextControlSheet.swift",
                "TronToolbarIconButton("
            ),
        ]

        for (path, token) in requiredUsages {
            let content = try source(at: iosRoot, path)
            #expect(
                content.contains(token),
                "\(path) should use \(token) so the visible control container remains tappable"
            )
        }

        for overlayPath in [
            "Sources/UI/Chat/Shell/ChatView.swift",
            "Sources/UI/Chat/Shell/ContentView.swift",
            "Sources/UI/Chat/Shell/SessionSidebar.swift",
            "Sources/UI/Onboarding/Flow/OnboardingFlowView.swift",
        ] {
            let content = try source(at: iosRoot, overlayPath)
            #expect(
                content.contains("TronNavigationTopBarOverlay") || content.contains("ShellTopBarOverlay"),
                "\(overlayPath) should keep visible top-bar controls outside SwiftUI's deforming navigation toolbar host"
            )
            #expect(
                !content.contains("ToolbarItem(placement: .topBarTrailing)"),
                "\(overlayPath) should not put visible glyph controls in topBarTrailing"
            )
            #expect(
                content.contains(".toolbar(.hidden, for: .navigationBar)"),
                "\(overlayPath) should keep the native navigation bar from intercepting top-bar taps"
            )
        }

        for toolbarPath in [
            "Sources/UI/Chat/Shell/ChatView+Toolbar.swift",
            "Sources/UI/Chat/Shell/ContentView.swift",
            "Sources/UI/Chat/Shell/ShellToolbarContent.swift",
            "Sources/UI/Components/SheetComponents.swift",
            "Sources/UI/Chat/Sheets/ContextControlSheet.swift",
            "Sources/UI/Settings/Shell/SettingsPageContainer.swift",
            "Sources/UI/Settings/Shell/SettingsView.swift",
            "Sources/UI/Onboarding/Flow/OnboardingFlowView.swift",
        ] {
            let content = try source(at: iosRoot, toolbarPath)
            #expect(
                !content.contains(".tronHitTarget(.circle)"),
                "\(toolbarPath) should use TronToolbarIconButton for toolbar glyph buttons"
            )
            #expect(
                !content.contains(".tronHitTarget(.fixedCircle"),
                "\(toolbarPath) should not use partial fixed-circle hit target fixes"
            )
        }
    }

    private func source(at root: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
