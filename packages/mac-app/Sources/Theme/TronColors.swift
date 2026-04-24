import SwiftUI
import AppKit

// MARK: - Tron Color Palette (Mac)
//
// Mirrors the emerald-centric palette from
// `packages/ios-app/Sources/Theme/TronColors.swift` so the Mac wizard,
// menu bar, and any future Mac surfaces share a visual identity with
// the iOS app. Hex values are identical to the iOS tokens — the only
// platform difference is `NSColor` vs `UIColor` for the adaptive
// dark/light provider.
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

    /// Static hex initializer — use for tokens that should not adapt
    /// across light/dark modes (rare; prefer the adaptive form).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (r, g, b) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }

    // MARK: - Accent Greens (mirrors iOS)

    /// Primary brand emerald — logo, headings, primary CTA fill.
    static let tronEmerald = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Deeper emerald — pressed state on the primary CTA.
    static let tronEmeraldDeep = Color(lightHex: "#047857", darkHex: "#059669")

    /// Brighter mint — gradient highlight, hover lift, link hover state.
    static let tronMint = Color(lightHex: "#10B981", darkHex: "#34D399")

    // MARK: - Semantic

    /// Success / "good to go" green — used by existing-install banner.
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

// MARK: - Gradients

extension LinearGradient {
    /// Top-to-bottom mint→emerald gradient. Use for the primary CTA
    /// background so the button has visible depth without losing its
    /// emerald identity at a glance.
    static let tronEmeraldGradient = LinearGradient(
        colors: [Color(hex: "#34D399"), Color(hex: "#10B981")],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - ShapeStyle Aliases

extension ShapeStyle where Self == Color {
    static var tronEmerald: Color { .tronEmerald }
    static var tronEmeraldDeep: Color { .tronEmeraldDeep }
    static var tronMint: Color { .tronMint }
    static var tronSuccess: Color { .tronSuccess }
}
