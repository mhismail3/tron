import Foundation
import Testing
import UIKit
@testable import TronMobile

@Suite("Preserved custom typography")
@MainActor
struct FontSettingsTests {
    private func isolatedSettings(_ label: String = #function) -> (FontSettings, UserDefaults) {
        let suite = "com.tron.tests.fonts.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FontSettings(defaults: defaults), defaults)
    }

    @Test("catalog and family roles match the established app")
    func catalog() {
        #expect(FontFamily.allCases.count == 11)
        #expect(FontFamily.textFamilies.count == 8)
        #expect(FontFamily.monoFamilies == [.recursive, .jetBrainsMono, .ibmPlexMono, .geistMono])
        #expect(FontFamily.sourceSerif4.systemFamilyName == "Source Serif 4 Variable")
        #expect(FontFamily.recursive.supportsMono)
        #expect(FontFamily.sourceSerif4.customAxes == [.weight, .opticalSize])
    }

    @Test("historical variable ranges are retained")
    func ranges() {
        #expect(FontFamily.libreBaskerville.weightRange == 400...700)
        #expect(FontFamily.lora.weightRange == 400...700)
        #expect(FontFamily.jetBrainsMono.weightRange == 100...800)
        #expect(FontAxis.opticalSize.range(for: .sourceSerif4) == 8...60)
        #expect(FontAxis.opticalSize.isAutomatic)
    }

    @Test("font and axis choices persist in the existing keys")
    func persistence() {
        let (settings, defaults) = isolatedSettings()
        settings.selectedFamily = .alanSans
        settings.selectedMonoFamily = .geistMono
        settings.setAxisValue(for: .recursive, axis: .casual, value: 0.9)
        let restored = FontSettings(defaults: defaults)
        #expect(restored.selectedFamily == .alanSans)
        #expect(restored.selectedMonoFamily == .geistMono)
        #expect(restored.axisValue(for: .recursive, axis: .casual) == 0.9)
    }

    @Test("every bundled family resolves instead of silently falling back")
    func everyFamilyResolves() {
        let (settings, _) = isolatedSettings()
        for family in FontFamily.allCases {
            let font = TronFontLoader.createUIFont(size: 14, weight: .regular, family: family, settings: settings)
            let expected = normalized(family.systemFamilyName)
            #expect(
                normalized(font.fontName).contains(expected) || normalized(font.familyName).contains(expected),
                "Expected \(family.displayName), got \(font.familyName) / \(font.fontName)"
            )
        }
    }

    @Test("Source Serif variable weights resolve without SwiftUI weight mutation")
    func sourceSerifWeights() {
        let (settings, _) = isolatedSettings()
        settings.selectedFamily = .sourceSerif4
        for weight in [TronFontLoader.Weight.light, .regular, .semibold, .bold, .black] {
            let font = TronFontLoader.createUIFont(size: 18, weight: weight, settings: settings)
            #expect(normalized(font.familyName).contains(normalized(FontFamily.sourceSerif4.systemFamilyName)))
        }
    }

    @Test("SwiftUI custom fonts opt into Dynamic Type scaling")
    func dynamicTypeScaling() {
        let (settings, _) = isolatedSettings()
        let base = TronFontLoader.createUIFont(size: 14, family: .sourceSerif4, settings: settings)
        let accessibility = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let scaled = UIFontMetrics.default.scaledFont(for: base, compatibleWith: accessibility)
        #expect(scaled.pointSize > base.pointSize)
    }

    @Test("selected code families resolve, including Recursive MONO")
    func codeFamilies() {
        let (settings, _) = isolatedSettings()
        for family in FontFamily.monoFamilies {
            settings.selectedMonoFamily = family
            let font = TronFontLoader.createUIFont(size: 13, weight: .medium, mono: true, settings: settings)
            #expect(normalized(font.familyName).contains(normalized(family.systemFamilyName)))
        }
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }
}
