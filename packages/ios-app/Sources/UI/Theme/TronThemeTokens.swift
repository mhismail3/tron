import SwiftUI

// MARK: - Tinted Component Colors

/// Derives role-based text and interactive element colors from an accent color,
/// with distinct light-mode (tinted) and dark-mode (neutral) palettes.
///
/// Light mode: names/headings use accent color; body/secondary text uses neutral gray tokens.
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

    /// Medium-emphasis text — descriptions, labels (light: neutral gray, dark: tronTextSecondary)
    let secondary: Color

    /// Section headers (light: accent, dark: tronTextSecondary)
    let heading: Color

    /// Body content — markdown, file names (light: neutral gray, dark: tronTextSecondary)
    let body: Color

    /// Dismiss/remove buttons (light: neutral muted, dark: tronTextSecondary)
    let dismiss: Color

    /// Very subtle icons — empty state, search (light: neutral muted, dark: tronTextMuted)
    let subtle: Color

    init(accent: Color, colorScheme: ColorScheme) {
        self.accent = accent
        if colorScheme == .light {
            name      = accent
            heading   = accent
            secondary = .tronTextSecondary
            body      = .tronTextSecondary
            dismiss   = .tronTextMuted
            subtle    = .tronTextMuted
        } else {
            name      = .tronTextPrimary
            secondary = .tronTextSecondary
            heading   = .tronTextSecondary
            body      = .tronTextSecondary
            dismiss   = .tronTextSecondary
            subtle    = .tronTextMuted
        }
    }

}

// MARK: - Reasoning Level Colors

extension Color {
    /// Reasoning level gradient — deep green (#1F5E3F) to bright teal (#00A69B).
    /// Interpolated linearly across available levels.
    private static let reasoningLowRGB: (CGFloat, CGFloat, CGFloat) = (31.0 / 255.0, 94.0 / 255.0, 63.0 / 255.0)
    private static let reasoningHighRGB: (CGFloat, CGFloat, CGFloat) = (0.0 / 255.0, 166.0 / 255.0, 155.0 / 255.0)

    static func reasoningLevel(_ level: String, levels: [String] = ["minimal", "low", "medium", "high", "xhigh"]) -> Color {
        let index = levels.firstIndex(of: level.lowercased()) ?? 0
        let progress = Double(index) / Double(max(levels.count - 1, 1))
        let (lr, lg, lb) = reasoningLowRGB
        let (hr, hg, hb) = reasoningHighRGB
        return Color(
            red: lr + progress * (hr - lr),
            green: lg + progress * (hg - lg),
            blue: lb + progress * (hb - lb)
        )
    }

    static func reasoningLevelIcon(_ level: String) -> String {
        switch level.lowercased() {
        case "minimal": return "leaf"
        case "low": return "hare"
        case "medium": return "brain"
        case "high": return "brain.fill"
        case "xhigh": return "sparkles"
        case "max": return "flame"
        default: return "brain"
        }
    }
}

// MARK: - Gradient Definitions

extension LinearGradient {
    /// Emerald gradient for assistant elements
    static let tronEmeraldGradient = LinearGradient(
        colors: [Color(hex: "#34D399"), Color(hex: "#10B981")],
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

    /// Snap animation for pull-up panel transitions
    static let tronSnap = Animation.spring(response: 0.30, dampingFraction: 0.82)
}

// MARK: - Animation Timing Constants

enum TronAnimationTiming {
    // MARK: - Message Cascade
    /// Stagger interval between messages (20ms)
    static let cascadeStaggerNanos: UInt64 = 20_000_000
    /// Maximum messages to cascade (cap at 1 second)
    static let cascadeMaxMessages = 50

    // MARK: - Capability Call Stagger
    /// Interval between capability appearances (80ms)
    static let capabilityStaggerNanos: UInt64 = 80_000_000
    /// Maximum capability stagger delay (200ms)
    static let capabilityStaggerCapNanos: UInt64 = 200_000_000

    // MARK: - Text Streaming
    /// Batch interval for text updates (100ms)
    static let textBatchNanos: UInt64 = 100_000_000

    // MARK: - InputBar Entrance Animation
    //
    // The input bar fades in two pieces over ~300ms after the chat
    // first becomes visible. Each delay below is the gap _between_
    // steps (not absolute), so the cumulative timeline is:
    //   t=0     onAppear
    //   t=200   attachment button morphs in
    //   t=300   trailing-padding gate flips (hasAppeared = true)

    /// Initial delay before the attachment button appears (200ms).
    static let inputBarAttachmentDelayNanos: UInt64 = 200_000_000
    /// Delay between the attachment button and the final hasAppeared flip (100ms).
    static let inputBarFinalDelayNanos: UInt64 = 100_000_000
    /// Spring used for both button morph-ins.
    static let inputBarButtonSpring: Animation = .spring(response: 0.4, dampingFraction: 0.8)
    /// Spring used for the final hasAppeared flip.
    static let inputBarFinalSpring: Animation = .spring(response: 0.35, dampingFraction: 0.85)
}

// MARK: - ShapeStyle Tokens for foregroundStyle

extension ShapeStyle where Self == Color {
    // Accent Greens
    static var tronEmerald: Color { .tronEmerald }
    static var tronEmeraldDark: Color { .tronEmeraldDark }
    static var tronMint: Color { .tronMint }

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
    static var tronSky: Color { .tronSky }
    static var tronIndigo: Color { .tronIndigo }
    static var tronTeal: Color { .tronTeal }
    static var tronCoral: Color { .tronCoral }
    static var tronRose: Color { .tronRose }
    static var tronPink: Color { .tronPink }

    // Warm colors (Tokens theme)
    static var tronAmberLight: Color { .tronAmberLight }

    // Cool neutral (Compact/Window theme)
    static var tronSlate: Color { .tronSlate }
    static var tronSlateDark: Color { .tronSlateDark }

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

    // Input Field Colors
    static var inputText: Color { .inputText }
    static var inputPlaceholder: Color { .inputPlaceholder }

    // Role Colors
    static var userBubble: Color { .userBubble }
    static var assistantBubble: Color { .assistantBubble }
    static var systemBubble: Color { .systemBubble }
    static var capabilityBubble: Color { .capabilityBubble }
    static var errorBubble: Color { .errorBubble }

    // Special Colors
    static var tronPhthaloGreen: Color { .tronPhthaloGreen }

    // Overlay
    static var tronOverlay: Color { .tronOverlay }
}
