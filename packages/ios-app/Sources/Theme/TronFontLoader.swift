import SwiftUI
import UIKit
import CoreText

/// Utility to create variable fonts with custom axis values
enum TronFontLoader {
    // MARK: - Variable Font Axis Tags

    enum AxisTag {
        static let weight: UInt32 = 0x77676874   // 'wght'
        static let casual: UInt32 = 0x4341534C   // 'CASL'
        static let mono: UInt32 = 0x4D4F4E4F     // 'MONO'
        static let slant: UInt32 = 0x736C6E74    // 'slnt'
        static let cursive: UInt32 = 0x43525356   // 'CRSV'
    }

    /// Weight values for variable fonts
    enum Weight: CGFloat {
        case light = 300
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700
        case heavy = 800
        case black = 900
    }

    // MARK: - Font Registration

    /// Register and verify all variable fonts at app startup
    static func registerFonts() {
        for family in FontFamily.allCases {
            if let _ = CGFont(family.fontName as CFString) {
                logger.info("\(family.displayName) variable font loaded", category: .ui)
            } else {
                logger.error("Failed to load \(family.displayName) variable font", category: .ui)
                #if DEBUG
                printAvailableFonts(matching: family.displayName.lowercased())
                #endif
            }
        }
    }

    /// Print matching font families (for debugging)
    static func printAvailableFonts(matching query: String? = nil) {
        logger.debug("=== Available Font Families ===", category: .ui)
        for familyName in UIFont.familyNames.sorted() {
            if let query, !familyName.lowercased().contains(query) { continue }
            logger.debug("Family: \(familyName)", category: .ui)
            for name in UIFont.fontNames(forFamilyName: familyName) {
                logger.debug("  - \(name)", category: .ui)
            }
        }
    }

    // MARK: - Variable Font Creation

    @MainActor
    static func createUIFont(
        size: CGFloat,
        weight: Weight = .regular,
        mono: Bool = false,
        casual: CGFloat? = nil,
        family: FontFamily? = nil
    ) -> UIFont {
        // Mono text always uses Recursive
        let resolvedFamily = mono ? .recursive : (family ?? FontSettings.shared.selectedFamily)
        let clampedWeight = clampWeight(weight.rawValue, for: resolvedFamily)

        let descriptor: UIFontDescriptor
        if resolvedFamily.isVariable {
            let variations = buildVariations(
                family: resolvedFamily,
                weight: clampedWeight,
                mono: mono,
                casual: casual
            )
            descriptor = UIFontDescriptor(fontAttributes: [
                .family: resolvedFamily.displayName,
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations,
            ])
        } else {
            // Static fonts: use traits for weight selection
            descriptor = UIFontDescriptor(fontAttributes: [.family: resolvedFamily.displayName])
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: uiFontWeight(from: weight)]])
        }

        let font = UIFont(descriptor: descriptor, size: size)

        // Verify we got the right font (case-insensitive match on family or font name)
        let expectedName = resolvedFamily.displayName.lowercased()
        if font.fontName.lowercased().contains(expectedName.replacingOccurrences(of: " ", with: ""))
            || font.familyName.lowercased().contains(expectedName) {
            return font
        }

        logger.warning("Font creation failed for \(resolvedFamily.displayName), using system fallback", category: .ui)
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
        casual: CGFloat? = nil,
        family: FontFamily? = nil
    ) -> Font {
        let uiFont = createUIFont(size: size, weight: weight, mono: mono, casual: casual, family: family)
        return Font(uiFont)
    }

    // MARK: - Variation Builder

    @MainActor
    private static func buildVariations(
        family: FontFamily,
        weight: CGFloat,
        mono: Bool,
        casual: CGFloat?
    ) -> [UInt32: CGFloat] {
        var variations: [UInt32: CGFloat] = [AxisTag.weight: weight]

        switch family {
        case .recursive:
            let actualCasual = casual ?? FontSettings.shared.axisValue(for: .recursive, axis: .casual)
            variations[AxisTag.mono] = mono ? 1.0 : 0.0
            variations[AxisTag.casual] = actualCasual
            variations[AxisTag.slant] = 0.0
            variations[AxisTag.cursive] = 0.0

        case .alanSans, .comme, .libreBaskerville, .vollkorn:
            break // weight-only

        case .ibmPlexSerif:
            break // static font — buildVariations should never be called for this
        }

        return variations
    }

    /// Clamp weight to the family's supported range
    private static func clampWeight(_ weight: CGFloat, for family: FontFamily) -> CGFloat {
        let range = family.weightRange
        return min(max(weight, range.lowerBound), range.upperBound)
    }

    // MARK: - Weight Conversion

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
