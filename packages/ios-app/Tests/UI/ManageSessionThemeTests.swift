import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Manage Session theme")
struct ManageSessionThemeTests {
    @Test("session accent is adaptive teal and readable in both appearances")
    func sessionAccentPalette() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightAccent = UIColor(Color.tronSessionTeal).resolvedColor(with: lightTraits)
        let darkAccent = UIColor(Color.tronSessionTeal).resolvedColor(with: darkTraits)

        #expect(lightAccent == UIColor(hex: "#0F766E"))
        #expect(darkAccent == UIColor(hex: "#2DD4BF"))
        #expect(contrastRatio(lightAccent, UIColor(Color.tronBackground).resolvedColor(with: lightTraits)) >= 3)
        #expect(contrastRatio(darkAccent, UIColor(Color.tronBackground).resolvedColor(with: darkTraits)) >= 3)
        #expect(TronSettingsVisualTheme(accent: .tronSessionTeal).accent == .tronSessionTeal)
    }

    @Test("Manage Session destinations install the inherited session theme")
    func destinationThemeRouting() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = [
            "Sources/UI/Chat/SessionContextSheet.swift",
            "Sources/UI/Chat/AgentInstructionsSheet.swift",
            "Sources/UI/Chat/SessionTreeSheet.swift",
            "Sources/UI/Chat/SessionProcessSheets.swift",
            "Sources/UI/Chat/WorkspaceInspectorSheet.swift",
            "Sources/UI/Settings/ProjectResourcesView.swift",
            "Sources/UI/Terminal/TerminalSheet.swift",
        ]

        for relativePath in sources {
            let source = try String(contentsOf: packageRoot.appendingPathComponent(relativePath))
            #expect(source.contains("tronSessionTeal"), relativePath)
        }

        let context = try String(contentsOf: packageRoot.appendingPathComponent(sources[0]))
        #expect(context.contains(".tronSettingsVisualTheme(accent: sessionRowAccent)"))
        #expect(context.contains("private var sessionRowAccent: Color { .tronSessionTeal }"))
    }

    private func contrastRatio(_ foreground: UIColor, _ background: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
