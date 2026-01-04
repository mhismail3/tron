import SwiftUI

// MARK: - Tron Color Palette

/// Forest green color palette inspired by the Tron TUI
extension Color {
    // MARK: - Primary Greens (from TUI theme.ts)

    /// Deep forest green - primary brand color
    static let tronPrimary = Color(hex: "#123524")

    /// Slightly lighter forest green
    static let tronPrimaryLight = Color(hex: "#1a4d2e")

    /// Bright forest green for emphasis
    static let tronPrimaryBright = Color(hex: "#2d5a3d")

    /// Vivid green for interactive elements
    static let tronPrimaryVivid = Color(hex: "#3a7d4a")

    /// Emerald green - assistant accent
    static let tronEmerald = Color(hex: "#4a9d6f")

    /// Mint green - user accent
    static let tronMint = Color(hex: "#5cb88c")

    /// Sage green - subtle accents
    static let tronSage = Color(hex: "#7acca6")

    // MARK: - Semantic Colors

    static let tronSuccess = Color.green
    static let tronWarning = Color.yellow
    static let tronError = Color.red
    static let tronInfo = Color.blue

    // MARK: - Backgrounds

    /// Deepest background
    static let tronBackground = Color(hex: "#0a1a10")

    /// Surface background (cards, etc)
    static let tronSurface = Color(hex: "#0f2418")

    /// Elevated surface background
    static let tronSurfaceElevated = Color(hex: "#152d1f")

    /// Subtle separator/border color
    static let tronBorder = Color(hex: "#1d3a28")

    // MARK: - Text Colors

    static let tronTextPrimary = Color.white
    static let tronTextSecondary = Color(white: 0.75)
    static let tronTextMuted = Color(white: 0.5)
    static let tronTextDisabled = Color(white: 0.35)

    // MARK: - Role Colors

    static let userBubble = Color.tronMint.opacity(0.15)
    static let assistantBubble = Color.tronSurface
    static let systemBubble = Color.tronPrimary.opacity(0.5)
    static let toolBubble = Color.tronInfo.opacity(0.15)
    static let errorBubble = Color.tronError.opacity(0.15)

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
    /// Primary Tron gradient for buttons and accents
    static let tronPrimaryGradient = LinearGradient(
        colors: [.tronPrimaryBright, .tronPrimary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Emerald gradient for assistant elements
    static let tronEmeraldGradient = LinearGradient(
        colors: [.tronMint, .tronEmerald],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Background gradient
    static let tronBackgroundGradient = LinearGradient(
        colors: [.tronBackground, Color(hex: "#050d08")],
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
