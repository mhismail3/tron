import SwiftUI
import UIKit
import CoreText

/// Utility to create variable Recursive fonts with custom axis values
enum TronFontLoader {
    // MARK: - Variable Font Axis Tags

    /// Recursive variable font axis tags (4-character codes as UInt32)
    /// See: https://recursive.design
    enum Axis {
        /// Weight axis: 300 (Light) to 1000 (Black)
        static let weight: UInt32 = 0x77676874 // 'wght'
        /// Casual axis: 0 (Linear) to 1 (Casual)
        static let casual: UInt32 = 0x4341534C // 'CASL'
        /// Monospace axis: 0 (Sans/Proportional) to 1 (Mono)
        static let mono: UInt32 = 0x4D4F4E4F // 'MONO'
        /// Slant axis: 0 to -15 degrees
        static let slant: UInt32 = 0x736C6E74 // 'slnt'
        /// Cursive axis: 0 (Roman) to 1 (Cursive) - auto-applied with slant
        static let cursive: UInt32 = 0x43525356 // 'CRSV'
    }

    /// Weight values for the variable font
    enum Weight: CGFloat {
        case light = 300
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700
        case heavy = 800
        case black = 900
    }

    // MARK: - Font Name

    /// PostScript name of the Recursive variable font
    private static let variableFontName = "Recursive"

    // MARK: - Font Registration

    /// Register and verify the variable font at app startup
    static func registerFonts() {
        if let _ = CGFont(variableFontName as CFString) {
            logger.info("Recursive variable font loaded successfully", category: .ui)
        } else {
            logger.error("Failed to load Recursive variable font", category: .ui)
            #if DEBUG
            printAvailableFonts()
            #endif
        }
    }

    /// Print all available font families (for debugging)
    static func printAvailableFonts() {
        logger.debug("=== Available Font Families ===", category: .ui)
        for family in UIFont.familyNames.sorted() {
            if family.lowercased().contains("recur") {
                logger.debug("Family: \(family)", category: .ui)
                for name in UIFont.fontNames(forFamilyName: family) {
                    logger.debug("  - \(name)", category: .ui)
                }
            }
        }
    }

    // MARK: - Variable Font Creation

    /// Create a UIFont with specific variable font axis values
    /// - Parameters:
    ///   - size: Font size in points
    ///   - weight: Weight value (300-1000)
    ///   - mono: Monospace axis (0 = proportional, 1 = monospace)
    ///   - casual: Casual axis (0 = linear, 1 = casual)
    /// - Returns: Configured UIFont, or system font fallback
    @MainActor
    static func createUIFont(
        size: CGFloat,
        weight: Weight = .regular,
        mono: Bool = false,
        casual: CGFloat? = nil
    ) -> UIFont {
        let actualCasual = casual ?? FontSettings.shared.casualAxis

        // Create font descriptor with variation axes
        let variations: [UIFontDescriptor.AttributeName: Any] = [
            .name: variableFontName,
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
                Axis.weight: weight.rawValue,
                Axis.mono: mono ? 1.0 : 0.0,
                Axis.casual: actualCasual,
                Axis.slant: 0.0,
                Axis.cursive: 0.0,
            ]
        ]

        let descriptor = UIFontDescriptor(fontAttributes: variations)

        // Try to create the variable font
        let font = UIFont(descriptor: descriptor, size: size)

        // Verify we got the right font (not a fallback)
        if font.fontName.contains("Recursive") || font.familyName.contains("Recursive") {
            return font
        }

        // Fallback to system font if variable font failed
        logger.warning("Variable font creation failed, using system fallback", category: .ui)
        return mono
            ? UIFont.monospacedSystemFont(ofSize: size, weight: uiFontWeight(from: weight))
            : UIFont.systemFont(ofSize: size, weight: uiFontWeight(from: weight))
    }

    /// Create a SwiftUI Font with specific variable font axis values
    @MainActor
    static func createFont(
        size: CGFloat,
        weight: Weight = .regular,
        mono: Bool = false,
        casual: CGFloat? = nil
    ) -> Font {
        let uiFont = createUIFont(size: size, weight: weight, mono: mono, casual: casual)
        return Font(uiFont)
    }

    // MARK: - Weight Conversion

    /// Convert our Weight enum to UIFont.Weight
    private static func uiFontWeight(from weight: Weight) -> UIFont.Weight {
        switch weight {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    /// Convert SwiftUI Font.Weight to our Weight enum
    static func weight(from fontWeight: Font.Weight) -> Weight {
        switch fontWeight {
        case .light, .ultraLight, .thin:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        default:
            return .regular
        }
    }

    /// Convert UIFont.Weight to our Weight enum
    static func weight(from uiFontWeight: UIFont.Weight) -> Weight {
        switch uiFontWeight {
        case .ultraLight, .thin, .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        default:
            return .regular
        }
    }
}
