import Testing
import SwiftUI
import UIKit
@testable import TronMobile

@MainActor
struct TronColorsTests {

    // MARK: - Helper to extract light/dark hex from adaptive Color

    private func lightHex(of color: Color) -> String {
        let uiColor = UIColor(color)
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        return hexString(from: resolved)
    }

    private func darkHex(of color: Color) -> String {
        let uiColor = UIColor(color)
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        return hexString(from: resolved)
    }

    private func hexString(from color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    // MARK: - Assistant Message Text

    @Test func assistantMessageTextLightIsDark() {
        #expect(lightHex(of: .assistantMessageText) == "#1C1917")
    }

    @Test func assistantMessageTextDarkIsUnchanged() {
        #expect(darkHex(of: .assistantMessageText) == "#FAFAFA")
    }

    // MARK: - Input Text Tokens

    @Test func inputTextLightIsEmerald() {
        #expect(lightHex(of: .inputText) == "#059669")
    }

    @Test func inputTextDarkIsEmerald() {
        #expect(darkHex(of: .inputText) == "#10B981")
    }

    @Test func inputPlaceholderLightIsSoftEmerald() {
        #expect(lightHex(of: .inputPlaceholder) == "#6EE7B7")
    }

    @Test func inputPlaceholderDarkIsMutedEmerald() {
        #expect(darkHex(of: .inputPlaceholder) == "#047857")
    }

    // MARK: - Dark Mode Preservation (critical: no regressions)

    @Test func darkModeColorsUnchanged() {
        // Core accent colors
        #expect(darkHex(of: .tronEmerald) == "#10B981")
        #expect(darkHex(of: .tronPrimary) == "#10B981")
        #expect(darkHex(of: .tronMint) == "#34D399")

        // Backgrounds
        #expect(darkHex(of: .tronBackground) == "#09090B")
        #expect(darkHex(of: .tronSurface) == "#18181B")
        #expect(darkHex(of: .tronSurfaceElevated) == "#27272A")

        // Text
        #expect(darkHex(of: .tronTextPrimary) == "#FAFAFA")
        #expect(darkHex(of: .tronTextSecondary) == "#A1A1AA")

        // Message colors
        #expect(darkHex(of: .userMessageText) == "#10B981")
        #expect(darkHex(of: .userBubble) == "#10B981")
        #expect(darkHex(of: .assistantBubble) == "#27272A")
    }

    // MARK: - TintedColors

    @Test func tintedColorsLightUsesNeutralText() {
        let tint = TintedColors(accent: .tronCyan, colorScheme: .light)
        // name stays accent, heading stays accent
        #expect(tint.accent == .tronCyan)
        // body and secondary should resolve to neutral gray (.tronTextSecondary)
        #expect(tint.body == .tronTextSecondary)
        #expect(tint.secondary == .tronTextSecondary)
    }

    @Test func tintedColorsDarkUsesNeutralText() {
        let tint = TintedColors(accent: .tronCyan, colorScheme: .dark)
        #expect(tint.name == .tronTextPrimary)
        #expect(tint.secondary == .tronTextSecondary)
        #expect(tint.body == .tronTextSecondary)
    }

    // MARK: - Light Mode Backgrounds (ensure warm cream preserved)

    @Test func lightModeBackgroundsAreWarmCream() {
        #expect(lightHex(of: .tronBackground) == "#F5F0E8")
        #expect(lightHex(of: .tronSurface) == "#FAF6EF")
        #expect(lightHex(of: .tronSurfaceElevated) == "#EDE8DF")
    }
}
