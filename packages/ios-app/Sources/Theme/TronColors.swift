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

    // MARK: - Accent Colors

    /// Primary accent - refined emerald
    static let tronPrimary = Color(hex: "#10B981")

    /// Light accent for hover/highlights
    static let tronPrimaryLight = Color(hex: "#34D399")

    /// Bright accent for emphasis
    static let tronPrimaryBright = Color(hex: "#6EE7B7")

    /// Vivid accent for interactive elements
    static let tronPrimaryVivid = Color(hex: "#10B981")

    /// Emerald - assistant accent
    static let tronEmerald = Color(hex: "#10B981")

    /// Darker emerald for send button
    static let tronEmeraldDark = Color(hex: "#059669")

    /// Mint - user accent
    static let tronMint = Color(hex: "#34D399")

    /// Sage - subtle accents
    static let tronSage = Color(hex: "#6EE7B7")

    // MARK: - Semantic Colors

    static let tronSuccess = Color(hex: "#10B981")
    static let tronWarning = Color(hex: "#F59E0B")
    static let tronError = Color(hex: "#EF4444")
    static let tronInfo = Color(hex: "#3B82F6")

    // Additional accent colors
    static let tronAmber = Color(hex: "#F59E0B")
    static let tronPurple = Color(hex: "#8B5CF6")
    static let tronBlue = Color(hex: "#3B82F6")
    static let tronCyan = Color(hex: "#06B6D4")
    static let tronIndigo = Color(hex: "#818CF8")
    static let tronTeal = Color(hex: "#2DD4BF")
    static let tronPink = Color(hex: "#EC4899")
    static let tronPinkLight = Color(hex: "#F472B6")

    // Warm colors (Tokens theme) - Earthy/muted palette
    static let tronAmberLight = Color(hex: "#D97706")
    static let tronOrange = Color(hex: "#C2410C")
    static let tronRed = Color(hex: "#B45309")
    static let tronBronze = Color(hex: "#78350F")

    // Earthy accent colors
    static let tronTerracotta = Color(hex: "#9A3412")
    static let tronClay = Color(hex: "#A16207")
    static let tronSienna = Color(hex: "#B45309")

    // Cool neutral (Compact/Window theme)
    static let tronSlate = Color(hex: "#64748B")
    static let tronSlateDark = Color(lightHex: "#CBD5E1", darkHex: "#334155")

    // Neutral gray
    static let tronGray = Color(hex: "#6B7280")

    // MARK: - Special Colors

    /// Phthalo green for iOS 26 liquid glass effect
    static let tronPhthaloGreen = Color(lightHex: "#A7F3D0", darkHex: "#123524")

    // MARK: - Backgrounds (adaptive)

    /// Deepest background (subtle warm cream tint in light mode)
    static let tronBackground = Color(lightHex: "#FAF9F7", darkHex: "#09090B")

    /// Surface background (cards, etc — barely perceptible cream tint in light mode)
    static let tronSurface = Color(lightHex: "#FDFCFB", darkHex: "#18181B")

    /// Elevated surface background (warm cream undertone in light mode)
    static let tronSurfaceElevated = Color(lightHex: "#F5F4F1", darkHex: "#27272A")

    /// Subtle separator/border color
    static let tronBorder = Color(lightHex: "#D4D4D8", darkHex: "#3F3F46")

    // MARK: - Text Colors (adaptive)

    static let tronTextPrimary = Color(lightHex: "#18181B", darkHex: "#FAFAFA")
    static let tronTextSecondary = Color(lightHex: "#52525B", darkHex: "#A1A1AA")
    static let tronTextMuted = Color(hex: "#71717A")
    static let tronTextDisabled = Color(lightHex: "#A1A1AA", darkHex: "#52525B")

    // MARK: - Role Colors (adaptive)

    static let userBubble = Color(hex: "#10B981")
    static let assistantBubble = Color(lightHex: "#F4F4F5", darkHex: "#27272A")
    static let systemBubble = Color(lightHex: "#E4E4E7", darkHex: "#3F3F46")
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

    func body(content: Content) -> some View {
        content
            .foregroundStyle(color)
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
        colors: [Color.tronBackground, Color(lightHex: "#F2F1EE", darkHex: "#000000")],
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
