import SwiftUI
import UIKit

// MARK: - Preserved Tron palette

extension Color {
    init(lightHex: String, darkHex: String) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: darkHex) : UIColor(hex: lightHex)
        })
    }

    static let tronEmerald = Color(lightHex: "#059669", darkHex: "#10B981")
    static let tronEmeraldDark = Color(lightHex: "#047857", darkHex: "#047857")
    static let tronAccentText = Color(lightHex: "#065F46", darkHex: "#6EE7B7")
    static let tronMint = Color(lightHex: "#10B981", darkHex: "#34D399")
    static let tronSuccess = Color(lightHex: "#15803D", darkHex: "#22C55E")
    static let tronWarning = Color(lightHex: "#D97706", darkHex: "#F59E0B")
    static let tronError = Color(lightHex: "#DC2626", darkHex: "#EF4444")
    static let tronInfo = Color(lightHex: "#0EA5E9", darkHex: "#38BDF8")
    static let tronAmber = Color(lightHex: "#D97706", darkHex: "#F59E0B")
    static let tronPurple = Color(lightHex: "#7C3AED", darkHex: "#8B5CF6")
    static let tronLavender = Color(lightHex: "#8B5CF6", darkHex: "#C4B5FD")
    static let tronBlue = Color(lightHex: "#2563EB", darkHex: "#3B82F6")
    static let tronCyan = Color(lightHex: "#0891B2", darkHex: "#06B6D4")
    static let tronSky = Color(lightHex: "#0284C7", darkHex: "#38BDF8")
    static let tronIndigo = Color(lightHex: "#6366F1", darkHex: "#818CF8")
    static let tronTeal = Color(lightHex: "#0D9488", darkHex: "#2DD4BF")
    static let tronCoral = Color(lightHex: "#C06545", darkHex: "#D97757")
    static let tronAutomation = Color(lightHex: "#B4D3D9", darkHex: "#B4D3D9")
    static let tronRose = Color(lightHex: "#D4245F", darkHex: "#E62B6C")
    static let tronPink = Color(lightHex: "#DB2777", darkHex: "#EC4899")
    static let tronSlate = Color(lightHex: "#64748B", darkHex: "#94A3B8")

    static let tronBackground = Color(lightHex: "#F7F8FA", darkHex: "#090A0C")
    /// Historical neutral tint used by the composer and terminal keyboard bar.
    static let tronPhthaloGreen = Color(lightHex: "#FFFFFF", darkHex: "#111827")
    static let tronSurface = Color(lightHex: "#FFFFFF", darkHex: "#16181D")
    static let tronSurfaceElevated = Color(lightHex: "#EEF2F6", darkHex: "#252A32")
    static let tronBorder = Color(lightHex: "#D8DEE6", darkHex: "#3B424D")
    static let tronTextPrimary = Color(lightHex: "#111827", darkHex: "#F8FAFC")
    static let tronTextSecondary = Color(lightHex: "#4B5563", darkHex: "#AAB2BF")
    static let tronTextMuted = Color(lightHex: "#6B7280", darkHex: "#8B949E")
    static let tronTextDisabled = Color(lightHex: "#9CA3AF", darkHex: "#5B6472")
    static let userMessageText = Color(lightHex: "#059669", darkHex: "#10B981")
    static let assistantMessageText = Color(lightHex: "#111827", darkHex: "#F8FAFC")
    static let inputText = Color(lightHex: "#059669", darkHex: "#10B981")
    static let inputPlaceholder = Color(lightHex: "#6EE7B7", darkHex: "#047857")
    static let userBubble = Color(lightHex: "#059669", darkHex: "#10B981")
    static let assistantBubble = Color(lightHex: "#EEF2F6", darkHex: "#252A32")
    static let systemBubble = Color(lightHex: "#E6EBF1", darkHex: "#323842")
    static let toolBubble = Color(lightHex: "#E0F2FE", darkHex: "#14324A")
    static let errorBubble = Color(lightHex: "#FEE2E2", darkHex: "#7F1D1D")
    static let tronSecondary = Color.tronTextSecondary

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

@MainActor
enum TronFont {
    static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(size: size, weight: TronFontLoader.weight(weight))
    }
    static func title(_ size: CGFloat = 24) -> Font { body(size, weight: .semibold) }
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(size: size, weight: TronFontLoader.weight(weight), mono: true)
    }
}

enum TronSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 14
    static let section: CGFloat = 16
    static let large: CGFloat = 20
    static let xlarge: CGFloat = 24
    static let bubblePadding: CGFloat = 12
    static let inputHorizontal: CGFloat = 14
    static let inputVertical: CGFloat = 10
    static let cornerMD: CGFloat = 10
    static let cornerLG: CGFloat = 16
    static let cornerInput: CGFloat = 18
}

extension View {
    func tronScreenBackground() -> some View { background { Color.tronBackground.ignoresSafeArea() } }
    func tronCard() -> some View {
        background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: TronSpacing.cornerLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TronSpacing.cornerLG).stroke(Color.tronBorder, lineWidth: 0.5))
    }
}

struct TronCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(TronSpacing.xxl)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.tronBorder.opacity(0.6), lineWidth: 0.5) }
    }
}

struct ConnectionBadge: View {
    let state: AppModel.ConnectionState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(TronTypography.secondaryCodeDescription)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
    private var color: Color {
        switch state {
        case .connected: .tronEmerald
        case .connecting, .reconnecting, .restarting: .tronWarning
        case .unpaired: .secondary
        case .unauthorized, .offline: .tronError
        }
    }
    private var label: String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .restarting: "Restarting"
        case .unpaired: "Not paired"
        case .unauthorized: "Re-pair required"
        case .offline: "Offline"
        }
    }
}
