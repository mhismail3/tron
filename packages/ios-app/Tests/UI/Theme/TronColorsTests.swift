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
        #expect(lightHex(of: .assistantMessageText) == "#111827")
    }

    @Test func assistantMessageTextDarkIsNeutralWhite() {
        #expect(darkHex(of: .assistantMessageText) == "#F8FAFC")
    }

    // MARK: - Input Text Tokens

    @Test func inputTextLightIsEmeraldPrimaryAccent() {
        #expect(lightHex(of: .inputText) == "#059669")
    }

    @Test func inputTextDarkIsEmeraldPrimaryAccent() {
        #expect(darkHex(of: .inputText) == "#10B981")
    }

    @Test func inputPlaceholderLightIsSoftEmerald() {
        #expect(lightHex(of: .inputPlaceholder) == "#6EE7B7")
    }

    @Test func inputPlaceholderDarkIsMutedEmerald() {
        #expect(darkHex(of: .inputPlaceholder) == "#047857")
    }

    // MARK: - Dark Mode Glass Tokens

    @Test func darkModeColorsUseNeutralGlassBaseline() {
        // Core accent colors
        #expect(darkHex(of: .tronEmerald) == "#10B981")
        #expect(darkHex(of: .tronMint) == "#34D399")

        // Backgrounds
        #expect(darkHex(of: .tronBackground) == "#090A0C")
        #expect(darkHex(of: .tronSurface) == "#16181D")
        #expect(darkHex(of: .tronSurfaceElevated) == "#252A32")

        // Text
        #expect(darkHex(of: .tronTextPrimary) == "#F8FAFC")
        #expect(darkHex(of: .tronTextSecondary) == "#AAB2BF")

        // Message colors
        #expect(darkHex(of: .userMessageText) == "#10B981")
        #expect(darkHex(of: .userBubble) == "#10B981")
        #expect(darkHex(of: .assistantBubble) == "#252A32")
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

    // MARK: - Light Mode Backgrounds

    @Test func lightModeBackgroundsAreNeutralGlass() {
        #expect(lightHex(of: .tronBackground) == "#F7F8FA")
        #expect(lightHex(of: .tronSurface) == "#FFFFFF")
        #expect(lightHex(of: .tronSurfaceElevated) == "#EEF2F6")
    }
}
