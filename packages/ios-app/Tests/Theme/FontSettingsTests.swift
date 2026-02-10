import Foundation
import Testing
@testable import TronMobile

@MainActor
struct FontFamilyTests {

    @Test func allCasesCount() {
        #expect(FontFamily.allCases.count == 3)
    }

    @Test func displayNames() {
        #expect(FontFamily.recursive.displayName == "Recursive")
        #expect(FontFamily.alanSans.displayName == "Alan Sans")
        #expect(FontFamily.comme.displayName == "Comme")
    }

    @Test func rawValueRoundTrip() {
        for family in FontFamily.allCases {
            let parsed = FontFamily(rawValue: family.rawValue)
            #expect(parsed == family)
        }
    }

    @Test func onlyRecursiveSupportsMono() {
        #expect(FontFamily.recursive.supportsMono == true)
        for family in FontFamily.allCases where family != .recursive {
            #expect(family.supportsMono == false)
        }
    }

    @Test func recursiveHasCasualAxis() {
        #expect(FontFamily.recursive.customAxes == [.casual])
    }

    @Test func weightOnlyFontsHaveNoCustomAxes() {
        #expect(FontFamily.alanSans.customAxes.isEmpty)
        #expect(FontFamily.comme.customAxes.isEmpty)
    }

    @Test func weightRanges() {
        #expect(FontFamily.recursive.weightRange == 300...1000)
        #expect(FontFamily.alanSans.weightRange == 300...900)
        #expect(FontFamily.comme.weightRange == 100...900)
    }
}

@MainActor
struct FontAxisTests {

    @Test func allCasesCount() {
        #expect(FontAxis.allCases.count == 1)
    }

    @Test func casualRange() {
        let range = FontAxis.casual.range(for: .recursive)
        #expect(range == 0...1)
    }

    @Test func defaultValues() {
        #expect(FontAxis.casual.defaultValue(for: .recursive) == 0.5)
    }

    @Test func labels() {
        #expect(FontAxis.casual.minLabel == "Linear")
        #expect(FontAxis.casual.maxLabel == "Casual")
    }

    @Test func tags() {
        #expect(FontAxis.casual.tag == 0x4341534C)
    }
}

@MainActor
struct FontSettingsTests {

    @Test func defaultFamilyIsRecursive() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.default")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.default")
        let settings = FontSettings(defaults: defaults)
        #expect(settings.selectedFamily == .recursive)
    }

    @Test func selectedFamilyPersists() {
        let settings = FontSettings.shared
        let original = settings.selectedFamily

        settings.selectedFamily = .alanSans
        #expect(UserDefaults.standard.string(forKey: "fontFamily") == "alanSans")

        settings.selectedFamily = .comme
        #expect(UserDefaults.standard.string(forKey: "fontFamily") == "comme")

        settings.selectedFamily = original
    }

    @Test func axisValueDefaultsWhenNotSet() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.axisDefault")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.axisDefault")
        let settings = FontSettings(defaults: defaults)
        #expect(settings.axisValue(for: .recursive, axis: .casual) == 0.5)
    }

    @Test func axisValueSetAndGet() {
        let settings = FontSettings.shared
        let original = settings.axisValue(for: .recursive, axis: .casual)

        settings.setAxisValue(for: .recursive, axis: .casual, value: 0.9)
        #expect(settings.axisValue(for: .recursive, axis: .casual) == 0.9)

        settings.setAxisValue(for: .recursive, axis: .casual, value: original)
    }

    @Test func axisValuesPreservedPerFont() {
        let settings = FontSettings.shared
        let origRecCasual = settings.axisValue(for: .recursive, axis: .casual)
        let origFamily = settings.selectedFamily

        settings.setAxisValue(for: .recursive, axis: .casual, value: 0.8)

        // Switching family doesn't lose Recursive's casual value
        settings.selectedFamily = .alanSans
        #expect(settings.axisValue(for: .recursive, axis: .casual) == 0.8)
        settings.selectedFamily = .recursive
        #expect(settings.axisValue(for: .recursive, axis: .casual) == 0.8)

        // Restore
        settings.setAxisValue(for: .recursive, axis: .casual, value: origRecCasual)
        settings.selectedFamily = origFamily
    }

    @Test func casualAxisBackwardCompatibility() {
        let settings = FontSettings.shared
        let original = settings.casualAxis

        settings.casualAxis = 0.7
        #expect(settings.axisValue(for: .recursive, axis: .casual) == 0.7)

        settings.setAxisValue(for: .recursive, axis: .casual, value: 0.3)
        #expect(settings.casualAxis == 0.3)

        settings.casualAxis = original
    }

    @Test func currentAxisValueFollowsSelectedFamily() {
        let settings = FontSettings.shared
        let origFamily = settings.selectedFamily

        settings.selectedFamily = .recursive
        settings.setAxisValue(for: .recursive, axis: .casual, value: 0.6)
        #expect(settings.currentAxisValue(for: .casual) == 0.6)

        settings.selectedFamily = origFamily
    }
}
