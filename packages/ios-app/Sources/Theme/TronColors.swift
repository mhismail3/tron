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

    /// Primary accent - refined emerald
    static let tronPrimary = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Light accent for hover/highlights
    static let tronPrimaryLight = Color(lightHex: "#10B981", darkHex: "#34D399")

    /// Bright accent for emphasis
    static let tronPrimaryBright = Color(lightHex: "#34D399", darkHex: "#6EE7B7")

    /// Vivid accent for interactive elements
    static let tronPrimaryVivid = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Emerald - assistant accent
    static let tronEmerald = Color(lightHex: "#059669", darkHex: "#10B981")

    /// Darker emerald for send button
    static let tronEmeraldDark = Color(lightHex: "#047857", darkHex: "#059669")

    /// Mint - user accent
    static let tronMint = Color(lightHex: "#10B981", darkHex: "#34D399")

    /// Sage - subtle accents
    static let tronSage = Color(lightHex: "#34D399", darkHex: "#6EE7B7")

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
    static let tronIndigo = Color(lightHex: "#6366F1", darkHex: "#818CF8")
    static let tronTeal = Color(lightHex: "#0D9488", darkHex: "#2DD4BF")
    static let tronPink = Color(lightHex: "#DB2777", darkHex: "#EC4899")
    static let tronPinkLight = Color(lightHex: "#EC4899", darkHex: "#F472B6")

    // Warm colors (Tokens theme) - Earthy/muted palette
    static let tronAmberLight = Color(lightHex: "#B45309", darkHex: "#D97706")
    static let tronOrange = Color(lightHex: "#9A3412", darkHex: "#C2410C")
    static let tronRed = Color(lightHex: "#92400E", darkHex: "#B45309")
    static let tronBronze = Color(lightHex: "#451A03", darkHex: "#78350F")

    // Earthy accent colors (adaptive: deeper in light mode)
    static let tronTerracotta = Color(lightHex: "#7C2D12", darkHex: "#9A3412")
    static let tronClay = Color(lightHex: "#854D0E", darkHex: "#A16207")
    static let tronSienna = Color(lightHex: "#92400E", darkHex: "#B45309")

    // Cool neutral (Compact/Window theme)
    static let tronSlate = Color(hex: "#64748B")
    static let tronSlateDark = Color(lightHex: "#CBD5E1", darkHex: "#334155")

    // Neutral gray
    static let tronGray = Color(hex: "#6B7280")

    // MARK: - Special Colors

    /// Phthalo green for iOS 26 liquid glass effect
    static let tronPhthaloGreen = Color(lightHex: "#34D399", darkHex: "#123524")

    // MARK: - Backgrounds (adaptive — warm cream in light mode)

    /// Deepest background
    static let tronBackground = Color(lightHex: "#F8F6F1", darkHex: "#09090B")

    /// Surface background (cards, sheets)
    static let tronSurface = Color(lightHex: "#FBF9F5", darkHex: "#18181B")

    /// Elevated surface background
    static let tronSurfaceElevated = Color(lightHex: "#F2F0EB", darkHex: "#27272A")

    /// Subtle separator/border color
    static let tronBorder = Color(lightHex: "#D4D4D8", darkHex: "#3F3F46")

    // MARK: - Text Colors (adaptive)

    static let tronTextPrimary = Color(lightHex: "#18181B", darkHex: "#FAFAFA")
    static let tronTextSecondary = Color(lightHex: "#52525B", darkHex: "#A1A1AA")
    static let tronTextMuted = Color(hex: "#71717A")
    static let tronTextDisabled = Color(lightHex: "#A1A1AA", darkHex: "#52525B")

    // MARK: - Message Text Colors (adaptive per role)

    /// User message text: black in light mode, emerald in dark mode
    static let userMessageText = Color(lightHex: "#18181B", darkHex: "#10B981")
    /// Assistant message text: emerald in light mode, near-white in dark mode
    static let assistantMessageText = Color(lightHex: "#059669", darkHex: "#FAFAFA")

    // MARK: - Role Colors (adaptive)

    static let userBubble = Color(lightHex: "#059669", darkHex: "#10B981")
    static let assistantBubble = Color(lightHex: "#F0EEE9", darkHex: "#27272A")
    static let systemBubble = Color(lightHex: "#E8E6E1", darkHex: "#3F3F46")
    static let toolBubble = Color(lightHex: "#DBEAFE", darkHex: "#1E3A5F")
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
        case .toolResult: return .toolBubble
        }
    }
}

// MARK: - Adaptive Section Fill

private struct SectionFillModifier: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    let subtle: Bool
    @Environment(\.colorScheme) var colorScheme

    private var opacity: Double {
        if subtle {
            return colorScheme == .dark ? 0.08 : 0.04
        } else {
            return colorScheme == .dark ? 0.15 : 0.08
        }
    }

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.opacity(opacity))
        }
    }
}

extension View {
    /// Adaptive section background fill — uses higher opacity in dark mode, lower in light mode.
    /// `subtle: true` for nested/inner rows (half the standard intensity).
    func sectionFill(_ color: Color, cornerRadius: CGFloat = 12, subtle: Bool = false) -> some View {
        self.modifier(SectionFillModifier(color: color, cornerRadius: cornerRadius, subtle: subtle))
    }

    /// Adaptive chip fill + stroke for capsule-shaped tool chips.
    func chipFill(_ color: Color, strokeOpacity: Double = 0.4) -> some View {
        self.modifier(ChipFillModifier(color: color, strokeOpacity: strokeOpacity))
    }
}

// MARK: - Adaptive Count Badge

private struct CountBadgeModifier: ViewModifier {
    let color: Color
    @Environment(\.colorScheme) var colorScheme

    private var bgOpacity: Double {
        colorScheme == .dark ? 0.7 : 0.18
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

private struct ChipFillModifier: ViewModifier {
    let color: Color
    let strokeOpacity: Double
    @Environment(\.colorScheme) var colorScheme

    private var fillOpacity: Double {
        colorScheme == .dark ? 0.15 : 0.08
    }

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(color.opacity(fillOpacity)))
            .overlay(Capsule().strokeBorder(color.opacity(strokeOpacity), lineWidth: 0.5))
    }
}

// MARK: - Tinted Component Colors

/// Derives role-based text and interactive element colors from an accent color,
/// with distinct light-mode (tinted) and dark-mode (neutral) palettes.
///
/// Light mode: text is tinted with the accent color at varying opacities.
/// Dark mode: text uses standard neutral tokens (.tronTextPrimary, .tronTextSecondary, etc.)
///
/// Usage:
/// ```swift
/// @Environment(\.colorScheme) private var colorScheme
/// private var tint: TintedColors { TintedColors(accent: .tronCyan, colorScheme: colorScheme) }
///
/// Text(name).foregroundStyle(tint.name)
/// Text(description).foregroundStyle(tint.secondary)
/// ```
struct TintedColors {
    /// The base accent color (always the same in both modes)
    let accent: Color

    /// Prominent text — names, row titles (light: accent, dark: tronTextPrimary)
    let name: Color

    /// Medium-emphasis text — descriptions, labels (light: accent@0.6, dark: tronTextSecondary)
    let secondary: Color

    /// Section headers (light: accent@0.7, dark: tronTextSecondary)
    let heading: Color

    /// Body content — markdown, file names (light: accent@0.6, dark: tronTextSecondary)
    let body: Color

    /// Dismiss/remove buttons (light: accent@0.5, dark: tronTextSecondary)
    let dismiss: Color

    /// Very subtle icons — empty state, search (light: accent@0.4, dark: tronTextMuted)
    let subtle: Color

    init(accent: Color, colorScheme: ColorScheme) {
        self.accent = accent
        if colorScheme == .light {
            name      = accent
            secondary = accent.opacity(0.6)
            heading   = accent.opacity(0.7)
            body      = accent.opacity(0.6)
            dismiss   = accent.opacity(0.5)
            subtle    = accent.opacity(0.4)
        } else {
            name      = .tronTextPrimary
            secondary = .tronTextSecondary
            heading   = .tronTextSecondary
            body      = .tronTextSecondary
            dismiss   = .tronTextSecondary
            subtle    = .tronTextMuted
        }
    }

    /// Convenience: create from ChipMode
    init(mode: ChipMode, colorScheme: ColorScheme) {
        self.init(accent: mode == .skill ? .tronCyan : .tronPink, colorScheme: colorScheme)
    }
}

// MARK: - Gradient Definitions

extension LinearGradient {
    /// Primary gradient for buttons and accents
    static let tronPrimaryGradient = LinearGradient(
        colors: [Color(hex: "#34D399"), Color(hex: "#10B981")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Emerald gradient for assistant elements
    static let tronEmeraldGradient = LinearGradient(
        colors: [Color(hex: "#34D399"), Color(hex: "#10B981")],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Background gradient (adaptive)
    static let tronBackgroundGradient = LinearGradient(
        colors: [Color.tronBackground, Color(lightHex: "#EDE9E0", darkHex: "#000000")],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Animation Presets

extension Animation {
    /// Standard Tron UI animation
    static let tronStandard = Animation.spring(response: 0.35, dampingFraction: 0.8)

    /// Fast Tron UI animation
    static let tronFast = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// Slow Tron UI animation for emphasis
    static let tronSlow = Animation.spring(response: 0.5, dampingFraction: 0.75)

    // MARK: - Specialized Animations

    /// Pill morph animation (context -> model -> reasoning)
    static let tronPillMorph = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Model pill appearance animation
    static let tronModelPill = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// Reasoning pill appearance animation
    static let tronReasoningPill = Animation.spring(response: 0.4, dampingFraction: 0.8)

    /// Tool call appearance animation
    static let tronToolAppear = Animation.spring(response: 0.35, dampingFraction: 0.8)

    /// Message cascade animation
    static let tronCascade = Animation.spring(response: 0.3, dampingFraction: 0.85)

    /// Token pill animation
    static let tronTokenPill = Animation.spring(response: 0.3, dampingFraction: 0.9)
}

// MARK: - Animation Timing Constants

enum TronAnimationTiming {
    // MARK: - Pill Morph Sequence
    /// Delay before context pill appears (immediate)
    static let contextPillDelayNanos: UInt64 = 0
    /// Delay between context and model pill (200ms)
    static let modelPillDelayNanos: UInt64 = 200_000_000
    /// Delay between model and reasoning pill (170ms)
    static let reasoningPillDelayNanos: UInt64 = 170_000_000

    // MARK: - Message Cascade
    /// Stagger interval between messages (20ms)
    static let cascadeStaggerNanos: UInt64 = 20_000_000
    /// Maximum messages to cascade (cap at 1 second)
    static let cascadeMaxMessages = 50

    // MARK: - Tool Call Stagger
    /// Interval between tool appearances (80ms)
    static let toolStaggerNanos: UInt64 = 80_000_000
    /// Maximum tool stagger delay (200ms)
    static let toolStaggerCapNanos: UInt64 = 200_000_000

    // MARK: - Text Streaming
    /// Batch interval for text updates (100ms)
    static let textBatchNanos: UInt64 = 100_000_000

    // MARK: - Entry Animation
    /// Delay for entry morph from left (180ms)
    static let entryMorphDelayNanos: UInt64 = 180_000_000
    /// Attachment button morph delay (350ms)
    static let attachmentButtonDelayNanos: UInt64 = 350_000_000
    /// Mic button morph delay after other elements (300ms)
    static let micButtonDelayNanos: UInt64 = 300_000_000
}

// MARK: - ShapeStyle Extension for foregroundStyle compatibility

extension ShapeStyle where Self == Color {
    // Primary Greens
    static var tronPrimary: Color { .tronPrimary }
    static var tronPrimaryLight: Color { .tronPrimaryLight }
    static var tronPrimaryBright: Color { .tronPrimaryBright }
    static var tronPrimaryVivid: Color { .tronPrimaryVivid }
    static var tronEmerald: Color { .tronEmerald }
    static var tronEmeraldDark: Color { .tronEmeraldDark }
    static var tronMint: Color { .tronMint }
    static var tronSage: Color { .tronSage }

    // Semantic Colors
    static var tronSuccess: Color { .tronSuccess }
    static var tronWarning: Color { .tronWarning }
    static var tronError: Color { .tronError }
    static var tronInfo: Color { .tronInfo }

    // Additional accent colors
    static var tronAmber: Color { .tronAmber }
    static var tronPurple: Color { .tronPurple }
    static var tronBlue: Color { .tronBlue }
    static var tronCyan: Color { .tronCyan }
    static var tronIndigo: Color { .tronIndigo }
    static var tronTeal: Color { .tronTeal }
    static var tronPink: Color { .tronPink }
    static var tronPinkLight: Color { .tronPinkLight }

    // Warm colors (Tokens theme)
    static var tronAmberLight: Color { .tronAmberLight }
    static var tronOrange: Color { .tronOrange }
    static var tronRed: Color { .tronRed }
    static var tronBronze: Color { .tronBronze }

    // Earthy accent colors
    static var tronTerracotta: Color { .tronTerracotta }
    static var tronClay: Color { .tronClay }
    static var tronSienna: Color { .tronSienna }

    // Cool neutral (Compact/Window theme)
    static var tronSlate: Color { .tronSlate }
    static var tronSlateDark: Color { .tronSlateDark }

    // Neutral gray
    static var tronGray: Color { .tronGray }

    // Backgrounds
    static var tronBackground: Color { .tronBackground }
    static var tronSurface: Color { .tronSurface }
    static var tronSurfaceElevated: Color { .tronSurfaceElevated }
    static var tronBorder: Color { .tronBorder }

    // Text Colors
    static var tronTextPrimary: Color { .tronTextPrimary }
    static var tronTextSecondary: Color { .tronTextSecondary }
    static var tronTextMuted: Color { .tronTextMuted }
    static var tronTextDisabled: Color { .tronTextDisabled }

    // Message Text Colors
    static var userMessageText: Color { .userMessageText }
    static var assistantMessageText: Color { .assistantMessageText }

    // Role Colors
    static var userBubble: Color { .userBubble }
    static var assistantBubble: Color { .assistantBubble }
    static var systemBubble: Color { .systemBubble }
    static var toolBubble: Color { .toolBubble }
    static var errorBubble: Color { .errorBubble }

    // Special Colors
    static var tronPhthaloGreen: Color { .tronPhthaloGreen }

    // Overlay
    static var tronOverlay: Color { .tronOverlay }
}
