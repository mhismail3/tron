import SwiftUI

// MARK: - Tron Color Palette

/// Refined dark color palette with green accents
extension Color {
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

    // MARK: - Special Colors

    /// Phthalo green for iOS 26 liquid glass effect
    static let tronPhthaloGreen = Color(hex: "#123524")

    // MARK: - Backgrounds (neutral dark grays)

    /// Deepest background - near black
    static let tronBackground = Color(hex: "#09090B")

    /// Surface background (cards, etc) - dark gray
    static let tronSurface = Color(hex: "#18181B")

    /// Elevated surface background
    static let tronSurfaceElevated = Color(hex: "#27272A")

    /// Subtle separator/border color
    static let tronBorder = Color(hex: "#3F3F46")

    // MARK: - Text Colors

    static let tronTextPrimary = Color(hex: "#FAFAFA")
    static let tronTextSecondary = Color(hex: "#A1A1AA")
    static let tronTextMuted = Color(hex: "#71717A")
    static let tronTextDisabled = Color(hex: "#52525B")

    // MARK: - Role Colors

    static let userBubble = Color(hex: "#10B981")
    static let assistantBubble = Color(hex: "#27272A")
    static let systemBubble = Color(hex: "#3F3F46")
    static let toolBubble = Color(hex: "#1E3A5F")
    static let errorBubble = Color(hex: "#7F1D1D")

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
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
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

    /// Background gradient
    static let tronBackgroundGradient = LinearGradient(
        colors: [Color(hex: "#09090B"), Color(hex: "#000000")],
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
}
