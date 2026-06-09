import SwiftUI
import UIKit

// MARK: - Tron Color Palette

extension Color {
    // MARK: - Adaptive Color Helper

    /// Creates a color that adapts to light/dark mode using UIColor dynamic provider
    init(lightHex: String, darkHex: String) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: darkHex)
                : UIColor(hex: lightHex)
        })
    }

    // MARK: - Accent Colors (adaptive: deeper in light mode)

    /// Emerald - assistant accent
    static let tronEmerald = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Darker emerald for send button
    static let tronEmeraldDark = Color(lightHex: "#047857", darkHex: "#059669")

    /// Mint - user accent
    static let tronMint = Color(lightHex: "#10B981", darkHex: "#34D399")

    // MARK: - Semantic Colors (adaptive: deeper in light mode)

    static let tronSuccess = Color(lightHex: "#059669", darkHex: "#10B981")
    static let tronWarning = Color(lightHex: "#D97706", darkHex: "#F59E0B")
    static let tronError = Color(lightHex: "#DC2626", darkHex: "#EF4444")
    static let tronInfo = Color(lightHex: "#2563EB", darkHex: "#3B82F6")

    // Additional accent colors (adaptive: deeper in light mode)
    static let tronAmber = Color(lightHex: "#D97706", darkHex: "#F59E0B")
    static let tronPurple = Color(lightHex: "#7C3AED", darkHex: "#8B5CF6")
    static let tronBlue = Color(lightHex: "#2563EB", darkHex: "#3B82F6")
    static let tronCyan = Color(lightHex: "#0891B2", darkHex: "#06B6D4")
    /// Sky - context operations accent (between tronInfo and tronCyan in hue)
    static let tronSky = Color(lightHex: "#0284C7", darkHex: "#38BDF8")
    static let tronIndigo = Color(lightHex: "#6366F1", darkHex: "#818CF8")
    static let tronTeal = Color(lightHex: "#0D9488", darkHex: "#2DD4BF")
    static let tronCoral = Color(lightHex: "#C06545", darkHex: "#D97757")
    static let tronRose = Color(lightHex: "#D4245F", darkHex: "#E62B6C")
    static let tronPink = Color(lightHex: "#DB2777", darkHex: "#EC4899")

    // Warm colors (Tokens theme) - Earthy/muted palette
    static let tronAmberLight = Color(lightHex: "#B45309", darkHex: "#D97706")

    // Cool neutral (Compact/Window theme)
    static let tronSlate = Color(hex: "#64748B")
    static let tronSlateDark = Color(lightHex: "#CBD5E1", darkHex: "#334155")

    // MARK: - Special Colors

    /// Glass tint — neutral in light mode (clear glass), deep green in dark mode
    static let tronPhthaloGreen = Color(lightHex: "#FFFFFF", darkHex: "#123524")

    // MARK: - Backgrounds (adaptive — warm cream in light mode)

    /// Deepest background
    static let tronBackground = Color(lightHex: "#F3EDE3", darkHex: "#09090B")

    /// Surface background (cards, sheets)
    static let tronSurface = Color(lightHex: "#F8F3EA", darkHex: "#18181B")

    /// Elevated surface background
    static let tronSurfaceElevated = Color(lightHex: "#EBE5DA", darkHex: "#27272A")

    /// Subtle separator/border color
    static let tronBorder = Color(lightHex: "#D4D4D8", darkHex: "#3F3F46")

    // MARK: - Text Colors (adaptive)

    static let tronTextPrimary = Color(lightHex: "#18181B", darkHex: "#FAFAFA")
    static let tronTextSecondary = Color(lightHex: "#52525B", darkHex: "#A1A1AA")
    static let tronTextMuted = Color(hex: "#71717A")
    static let tronTextDisabled = Color(lightHex: "#A1A1AA", darkHex: "#52525B")

    // MARK: - Message Text Colors (adaptive per role)

    /// User message text: dark emerald in light mode, emerald in dark mode
    static let userMessageText = Color(lightHex: "#059669", darkHex: "#10B981")
    /// Assistant message text: dark in light mode for readability, near-white in dark mode
    static let assistantMessageText = Color(lightHex: "#1C1917", darkHex: "#FAFAFA")

    /// Input field text: emerald in both modes (deeper shade in light)
    static let inputText = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Input field placeholder: soft emerald in light, muted emerald in dark
    static let inputPlaceholder = Color(lightHex: "#6EE7B7", darkHex: "#047857")

    // MARK: - Role Colors (adaptive)

    static let userBubble = Color(lightHex: "#059669", darkHex: "#10B981")
    static let assistantBubble = Color(lightHex: "#EBE5DA", darkHex: "#27272A")
    static let systemBubble = Color(lightHex: "#E3DDCF", darkHex: "#3F3F46")
    static let capabilityBubble = Color(lightHex: "#DBEAFE", darkHex: "#1E3A5F")
    static let errorBubble = Color(lightHex: "#FEE2E2", darkHex: "#7F1D1D")

    // MARK: - Overlay Colors

    /// Adaptive overlay: white in dark mode, black in light mode.
    /// Use with `.opacity()` for subtle background overlays that brighten/darken relative to the surface.
    static let tronOverlay = Color(lightHex: "#000000", darkHex: "#FFFFFF")

    /// Convenience: returns tronOverlay at the given opacity
    static func tronOverlay(_ opacity: Double) -> Color {
        tronOverlay.opacity(opacity)
    }

    // MARK: - Adaptive Color Composition

    /// Creates a color that resolves to different existing Color values in light vs dark mode.
    /// Use when you want to compose adaptive colors from existing tokens rather than raw hex.
    ///
    ///     // Different per mode:
    ///     let name = Color.adaptive(light: .tronCyan, dark: .tronTextPrimary)
    ///     // Same in both modes (pass one value):
    ///     let accent = Color.adaptive(.tronCyan)
    ///
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// Convenience: same color in both modes (no adaptation).
    static func adaptive(_ color: Color) -> Color {
        color
    }

    // MARK: - Hex Initializer

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - UIColor Hex Helper

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: CGFloat
        switch hex.count {
        case 3:
            r = CGFloat((int >> 8) * 17) / 255
            g = CGFloat((int >> 4 & 0xF) * 17) / 255
            b = CGFloat((int & 0xF) * 17) / 255
        case 6:
            r = CGFloat(int >> 16) / 255
            g = CGFloat(int >> 8 & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - View Modifiers

extension View {
    /// Cream background that extends behind the keyboard and into all safe areas.
    /// Apply to full-screen views that contain glass components (ChatView, SessionSidebar,
    /// session lists) — glass effects need a nearby opaque surface to create visible depth/shadow.
    /// Also applied at root (ContentView, TronMobileApp loading states) for overall coverage.
    /// Do NOT apply to sheets — they use the iOS 26 translucent glass material.
    @ViewBuilder
    func tronScreenBackground() -> some View {
        self.background { Color.tronBackground.ignoresSafeArea() }
    }

    /// Applies Tron glass background effect
    @ViewBuilder
    func tronGlassBackground() -> some View {
        self
            .background(.ultraThinMaterial)
            .background(Color.tronSurface.opacity(0.5))
    }

    /// Applies Tron card styling
    @ViewBuilder
    func tronCard() -> some View {
        self
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.tronBorder, lineWidth: 0.5)
            )
    }

    /// Applies Tron elevated card styling
    @ViewBuilder
    func tronElevatedCard() -> some View {
        self
            .background(Color.tronSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    /// Applies Tron message bubble styling
    @ViewBuilder
    func tronBubble(role: MessageRole) -> some View {
        self
            .padding(12)
            .background(bubbleColor(for: role))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bubbleColor(for role: MessageRole) -> Color {
        switch role {
        case .user: return .userBubble
        case .assistant: return .assistantBubble
        case .system: return .systemBubble
        case .capability: return .capabilityBubble
        }
    }
}

// MARK: - Adaptive Section Fill

private struct SectionFillModifier: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    let subtle: Bool
    let compact: Bool
    let interactive: Bool
    @Environment(\.colorScheme) var colorScheme

    private var opacity: Double {
        if subtle {
            return colorScheme == .dark ? 0.08 : 0.06
        } else {
            return colorScheme == .dark ? 0.15 : 0.10
        }
    }

    private var glassOpacity: Double {
        subtle ? 0.12 : 0.2
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if compact {
            if interactive {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(
                        .regular.tint(color.opacity(glassOpacity)).interactive(),
                        in: shape
                    )
            } else {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(
                        .regular.tint(color.opacity(glassOpacity)),
                        in: shape
                    )
            }
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape.fill(color.opacity(opacity))
                }
        }
    }
}

extension View {
    /// Adaptive section background fill — uses higher opacity in dark mode, lower in light mode.
    /// `subtle: true` for nested/inner rows (half the standard intensity).
    /// `compact: false` forces plain fill instead of glass (for large content that causes rendering glitches).
    func sectionFill(_ color: Color, cornerRadius: CGFloat = 12, subtle: Bool = false, compact: Bool = true, interactive: Bool = true) -> some View {
        self.modifier(SectionFillModifier(color: color, cornerRadius: cornerRadius, subtle: subtle, compact: compact, interactive: interactive))
    }

}

// MARK: - Adaptive Count Badge

private struct CountBadgeModifier: ViewModifier {
    let color: Color
    @Environment(\.colorScheme) var colorScheme

    private var bgOpacity: Double {
        colorScheme == .dark ? 0.7 : 0.25
    }

    private var textColor: Color {
        colorScheme == .dark ? .white : color
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(bgOpacity))
            .clipShape(Capsule())
    }
}

extension View {
    /// Adaptive count badge — color-matched text with adaptive background opacity.
    func countBadge(_ color: Color) -> some View {
        self.modifier(CountBadgeModifier(color: color))
    }
}

// MARK: - Chip Style

private struct ChipStyleModifier: ViewModifier {
    let tintColor: Color
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular.tint(tintColor.opacity(tintOpacity)).interactive(),
            in: .capsule
        )
    }
}

private struct ChipStyleMaterialModifier: ViewModifier {
    let tintColor: Color
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular.tint(tintColor.opacity(tintOpacity)).interactive(),
            in: .capsule
        )
    }
}

extension View {
    /// Applies the standard capsule glass effect.
    func chipStyle(_ tintColor: Color, tintOpacity: Double = 0.35) -> some View {
        modifier(ChipStyleModifier(tintColor: tintColor, tintOpacity: tintOpacity))
    }

    /// Applies the standard capsule material glass effect.
    func chipStyleMaterial(_ tintColor: Color, tintOpacity: Double = 0.35) -> some View {
        modifier(ChipStyleMaterialModifier(tintColor: tintColor, tintOpacity: tintOpacity))
    }
}
