import SwiftUI
import AppKit

// MARK: - Tron Color Palette (Mac)
//
// The Mac wizard and menu bar's emerald-centric palette. It follows the iOS
// palette's look (`packages/ios-app/Sources/UI/Theme/TronTheme.swift`) but
// is its own set of values; some tokens differ from iOS. Colors adapt to
// dark and light appearance through `NSColor`.
//
// Adding a new token here? Add the matching token to the iOS side too,
// and vice versa. Drift between platforms is the bug that doc tables
// are designed to prevent.

extension Color {
    /// Adaptive color: deeper shade in light mode, brighter in dark mode.
    init(lightHex: String, darkHex: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark,
            ]) != nil
            return NSColor(hex: isDark ? darkHex : lightHex)
        })
    }

    // MARK: - Accent Greens (mirrors iOS)

    /// Primary brand emerald — logo, headings, primary CTA fill.
    static let tronEmerald = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Deeper emerald — pressed state on the primary CTA.
    static let tronEmeraldDeep = Color(lightHex: "#047857", darkHex: "#059669")

    /// Brighter mint — gradient highlight, hover lift, link hover state.
    static let tronMint = Color(lightHex: "#10B981", darkHex: "#34D399")

    // MARK: - Semantic

    /// Success / "good to go" green used by wizard status cards.
    static let tronSuccess = Color(lightHex: "#059669", darkHex: "#10B981")
}

// MARK: - NSColor Hex Helper

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat(int >> 16) / 255
            g = CGFloat(int >> 8 & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
