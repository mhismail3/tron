import SwiftUI
import AppKit

extension Color {
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

    static let tronEmerald = Color(lightHex: "#059669", darkHex: "#10B981")

    static let tronEmeraldDeep = Color(lightHex: "#047857", darkHex: "#059669")

    static let tronMint = Color(lightHex: "#10B981", darkHex: "#34D399")

    static let tronSuccess = Color(lightHex: "#059669", darkHex: "#10B981")
}

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
