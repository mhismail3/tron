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

        #expect(lightAccent == UIColor(hex: "#0E7490"))
        #expect(darkAccent == UIColor(hex: "#67E8F9"))
        #expect(contrastRatio(lightAccent, UIColor(Color.tronBackground).resolvedColor(with: lightTraits)) >= 4.5)
        #expect(contrastRatio(darkAccent, UIColor(Color.tronBackground).resolvedColor(with: darkTraits)) >= 4.5)
        #expect(TronSettingsVisualTheme(accent: .tronSessionTeal).accent == .tronSessionTeal)
    }

    @Test("Knowledge violet accent is adaptive and readable in both appearances")
    func knowledgeAccentPalette() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightAccent = UIColor(Color.tronKnowledge).resolvedColor(with: lightTraits)
        let darkAccent = UIColor(Color.tronKnowledge).resolvedColor(with: darkTraits)
        #expect(lightAccent == UIColor(hex: "#6D3BB8"))
        #expect(darkAccent == UIColor(hex: "#C4B5FD"))
        #expect(contrastRatio(lightAccent, UIColor(Color.tronBackground).resolvedColor(with: lightTraits)) >= 4.5)
        #expect(contrastRatio(darkAccent, UIColor(Color.tronBackground).resolvedColor(with: darkTraits)) >= 4.5)
        #expect(TronSettingsVisualTheme(accent: .tronKnowledge).accent == .tronKnowledge)
        #expect(Color.tronKnowledgeText != Color.tronAutomationText)
    }

    @Test("subagent history shares active amber while retaining its terminal seafoam theme")
    @MainActor
    func subagentTheme() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        #expect(UIColor(Color.tronSubagent).resolvedColor(with: dark) == UIColor(hex: "#03C3A8"))
        for traits in [light, dark] {
            let background = UIColor(Color.tronBackground).resolvedColor(with: traits)
            for color in [Color.tronSubagent, ChatNotificationTone.subagent.primaryColor, ChatNotificationTone.subagent.secondaryColor] {
                #expect(contrastRatio(UIColor(color).resolvedColor(with: traits), background) >= 4.5)
            }
        }
        #expect(ChatNotificationTone.subagent.surfaceColor == .tronSubagent)
        for state: SessionProcessLifecycleState in [.queued, .running, .paused] {
            #expect(SessionProcessRowStyle.activity.accent(for: state) == .tronAmber)
            #expect(SessionProcessRowStyle.history.accent(for: state) == .tronAmber)
        }
        #expect(SessionProcessRowStyle.activity.accent(for: .completed) == .tronSuccess)
        #expect(SessionProcessRowStyle.history.accent(for: .completed) == .tronSubagent)
        for state: SessionProcessLifecycleState in [.failed, .stopped, .rejected, .interrupted, .unknown] {
            #expect(SessionProcessRowStyle.activity.accent(for: state) == .tronError)
            #expect(SessionProcessRowStyle.history.accent(for: state) == .tronSubagent)
        }
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
