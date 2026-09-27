import CoreText
import SwiftUI
import UIKit

/// Creates the bundled static and variable fonts without applying unsupported
/// SwiftUI weight mutations to a named variable face.
@MainActor
enum TronFontLoader {
    enum Weight: CGFloat {
        case light = 300, regular = 400, medium = 500, semibold = 600, bold = 700, heavy = 800, black = 900
    }

    static func createFont(
        size: CGFloat,
        weight: Weight = .regular,
        mono: Bool = false,
        casual: CGFloat? = nil,
        family: FontFamily? = nil,
        settings: FontSettings = .shared
    ) -> Font {
        let key = cacheKey(size: size, weight: weight, mono: mono, casual: casual, family: family, settings: settings)
        if let cached = fontCache[key] { return cached }
        let base = uiFont(for: key)
        // `relativeTo:` carries Dynamic Type metadata into SwiftUI's environment;
        // wrapping a UIFont/CTFont alone renders the right pixels but audits as fixed.
        let font = Font.custom(base.fontName, size: size, relativeTo: textStyle(for: size))
        if fontCache.count >= cacheLimit { fontCache.removeAll(keepingCapacity: true) }
        fontCache[key] = font
        return font
    }

    static func createUIFont(
        size: CGFloat,
        weight: Weight = .regular,
        mono: Bool = false,
        casual: CGFloat? = nil,
        family: FontFamily? = nil,
        settings: FontSettings = .shared
    ) -> UIFont {
        uiFont(for: cacheKey(size: size, weight: weight, mono: mono, casual: casual, family: family, settings: settings))
    }

    /// Every input that shapes the created font. Views call these loaders from
    /// their bodies, so resolved fonts are reused by exact key; building the key
    /// reads the same `FontSettings` properties as an uncached build, so font
    /// setting changes still invalidate the calling views through observation.
    /// Dynamic Type is not an input: SwiftUI (`relativeTo:`) and callers'
    /// `UIFontMetrics` scale the unscaled base at render time.
    private struct CacheKey: Hashable {
        let family: FontFamily
        let size: CGFloat
        let weight: Weight
        let mono: Bool
        let preferredWeight: Double
        /// Recursive's effective `CASL` value; nil for every other family.
        let casual: CGFloat?
    }

    /// Bounds the caches when continuous axis sliders produce new keys.
    private static let cacheLimit = 256
    private static var uiFontCache: [CacheKey: UIFont] = [:]
    private static var fontCache: [CacheKey: Font] = [:]

    private static func cacheKey(
        size: CGFloat,
        weight: Weight,
        mono: Bool,
        casual: CGFloat?,
        family: FontFamily?,
        settings: FontSettings
    ) -> CacheKey {
        let resolved = mono ? (family ?? settings.selectedMonoFamily) : (family ?? settings.selectedFamily)
        return CacheKey(
            family: resolved,
            size: size,
            weight: weight,
            mono: mono,
            preferredWeight: settings.axisValue(for: resolved, axis: .weight),
            casual: resolved == .recursive
                ? casual ?? CGFloat(settings.axisValue(for: resolved, axis: .casual))
                : nil
        )
    }

    private static func uiFont(for key: CacheKey) -> UIFont {
        if let cached = uiFontCache[key] { return cached }
        let font = makeUIFont(for: key)
        if uiFontCache.count >= cacheLimit { uiFontCache.removeAll(keepingCapacity: true) }
        uiFontCache[key] = font
        return font
    }

    private static func makeUIFont(for key: CacheKey) -> UIFont {
        let resolved = key.family
        let size = key.size
        let weight = key.weight
        let mono = key.mono
        let preferred = CGFloat(key.preferredWeight)
        let shifted = weight.rawValue + preferred - CGFloat(FontAxis.weight.defaultValue(for: resolved))
        let clamped = min(max(shifted, CGFloat(resolved.weightRange.lowerBound)), CGFloat(resolved.weightRange.upperBound))
        let descriptor: UIFontDescriptor
        if resolved.isVariable {
            var variations: [UInt32: CGFloat] = [FontAxis.weight.tag: clamped]
            if resolved == .recursive, let casual = key.casual {
                variations[0x4D4F4E4F] = mono ? 1 : 0 // MONO
                variations[FontAxis.casual.tag] = casual
                variations[0x736C6E74] = 0 // slnt
                variations[0x43525356] = 0 // CRSV
            }
            if resolved == .sourceSerif4 {
                let range = FontAxis.opticalSize.range(for: resolved)
                variations[FontAxis.opticalSize.tag] = min(max(size, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
            }
            descriptor = UIFontDescriptor(fontAttributes: [
                .family: resolved.systemFamilyName,
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations,
            ])
        } else {
            descriptor = UIFontDescriptor(fontAttributes: [.family: resolved.systemFamilyName])
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: uiWeight(weight)]])
        }
        let font = UIFont(descriptor: descriptor, size: size)
        let expected = normalized(resolved.systemFamilyName)
        if normalized(font.fontName).contains(expected) || normalized(font.familyName).contains(expected) {
            return font
        }
        return (mono || resolved.category == .mono)
            ? .monospacedSystemFont(ofSize: size, weight: uiWeight(weight))
            : .systemFont(ofSize: size, weight: uiWeight(weight))
    }

    static func weight(_ value: Font.Weight) -> Weight {
        switch value {
        case .light, .ultraLight, .thin: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    static func weight(_ value: UIFont.Weight) -> Weight {
        switch value {
        case .ultraLight, .thin, .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<10: .caption2
        case ..<12: .caption
        case ..<13: .footnote
        case ..<14: .subheadline
        case ..<16: .body
        case ..<20: .headline
        case ..<24: .title3
        case ..<28: .title2
        default: .title
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }
    private static func uiWeight(_ value: Weight) -> UIFont.Weight {
        switch value {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}
