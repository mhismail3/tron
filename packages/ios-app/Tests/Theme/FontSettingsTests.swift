import Foundation
import Testing
@testable import TronMobile

@MainActor
struct FontFamilyTests {

    @Test func allCasesCount() {
        #expect(FontFamily.allCases.count == 11)
    }

    @Test func displayNames() {
        #expect(FontFamily.recursive.displayName == "Recursive")
        #expect(FontFamily.alanSans.displayName == "Alan Sans")
        #expect(FontFamily.comme.displayName == "Comme")
        #expect(FontFamily.donegalOne.displayName == "Donegal One")
        #expect(FontFamily.ibmPlexSerif.displayName == "IBM Plex Serif")
        #expect(FontFamily.libreBaskerville.displayName == "Libre Baskerville")
        #expect(FontFamily.sourceSerif4.displayName == "Source Serif 4")
        #expect(FontFamily.lora.displayName == "Lora")
        #expect(FontFamily.jetBrainsMono.displayName == "JetBrains Mono")
        #expect(FontFamily.ibmPlexMono.displayName == "IBM Plex Mono")
        #expect(FontFamily.geistMono.displayName == "Geist Mono")
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
        #expect(FontFamily.recursive.customAxes.contains(.casual))
        #expect(FontFamily.recursive.customAxes.contains(.weight))
    }

    @Test func opticalSizeFontsHaveOpszAxis() {
        #expect(FontFamily.sourceSerif4.customAxes.contains(.opticalSize))
        #expect(FontFamily.sourceSerif4.customAxes.contains(.weight))
    }

    @Test func variableFontsHaveWeightAxis() {
        let variableFonts: [FontFamily] = [
            .recursive, .alanSans, .comme, .libreBaskerville,
            .sourceSerif4, .lora, .jetBrainsMono, .geistMono,
        ]
        for family in variableFonts {
            #expect(family.customAxes.contains(.weight), "\(family.displayName) should have weight axis")
        }
    }

    @Test func staticFontsHaveNoCustomAxes() {
        let staticFonts: [FontFamily] = [.donegalOne, .ibmPlexSerif, .ibmPlexMono]
        for family in staticFonts {
            #expect(family.customAxes.isEmpty, "Expected no custom axes for \(family.displayName)")
        }
    }

    @Test func weightRanges() {
        #expect(FontFamily.recursive.weightRange == 300...1000)
        #expect(FontFamily.alanSans.weightRange == 300...900)
        #expect(FontFamily.comme.weightRange == 100...900)
        #expect(FontFamily.donegalOne.weightRange == 400...400)
        #expect(FontFamily.ibmPlexSerif.weightRange == 300...700)
        #expect(FontFamily.libreBaskerville.weightRange == 400...700)
        #expect(FontFamily.sourceSerif4.weightRange == 200...900)
        #expect(FontFamily.lora.weightRange == 400...700)
        #expect(FontFamily.jetBrainsMono.weightRange == 100...800)
        #expect(FontFamily.ibmPlexMono.weightRange == 300...700)
        #expect(FontFamily.geistMono.weightRange == 100...900)
    }

    @Test func variableFontClassification() {
        let variable: [FontFamily] = [
            .recursive, .alanSans, .comme, .libreBaskerville,
            .sourceSerif4, .lora, .jetBrainsMono, .geistMono,
        ]
        for family in variable {
            #expect(family.isVariable == true, "\(family.displayName) should be variable")
        }

        let staticFonts: [FontFamily] = [.donegalOne, .ibmPlexSerif, .ibmPlexMono]
        for family in staticFonts {
            #expect(family.isVariable == false, "\(family.displayName) should be static")
        }
    }

    // MARK: - Category Tests

    @Test func categoryAssignment() {
        #expect(FontFamily.recursive.category == .sans)
        #expect(FontFamily.alanSans.category == .sans)
        #expect(FontFamily.comme.category == .sans)

        #expect(FontFamily.donegalOne.category == .serif)
        #expect(FontFamily.ibmPlexSerif.category == .serif)
        #expect(FontFamily.libreBaskerville.category == .serif)
        #expect(FontFamily.sourceSerif4.category == .serif)
        #expect(FontFamily.lora.category == .serif)

        #expect(FontFamily.jetBrainsMono.category == .mono)
        #expect(FontFamily.ibmPlexMono.category == .mono)
        #expect(FontFamily.geistMono.category == .mono)
    }

    @Test func textFamiliesExcludeMono() {
        let textFamilies = FontFamily.textFamilies
        for family in textFamilies {
            #expect(family.category != .mono, "\(family.displayName) should not be in textFamilies")
        }
        #expect(textFamilies.count == 8)
    }

    @Test func monoFamiliesIncludeRecursiveAndMonoCategory() {
        let monoFamilies = FontFamily.monoFamilies
        #expect(monoFamilies.contains(.recursive))
        #expect(monoFamilies.contains(.jetBrainsMono))
        #expect(monoFamilies.contains(.ibmPlexMono))
        #expect(monoFamilies.contains(.geistMono))
        #expect(monoFamilies.count == 4)
    }

    @Test func everyFamilyHasNonEmptyFontName() {
        for family in FontFamily.allCases {
            #expect(!family.fontName.isEmpty, "\(family.displayName) has empty fontName")
        }
    }

    @Test func everyFamilyHasNonEmptyShortDescription() {
        for family in FontFamily.allCases {
            #expect(!family.shortDescription.isEmpty, "\(family.displayName) has empty shortDescription")
        }
    }

    @Test func weightRangeLowerBoundNeverExceedsUpper() {
        for family in FontFamily.allCases {
            #expect(
                family.weightRange.lowerBound <= family.weightRange.upperBound,
                "\(family.displayName) has invalid weight range"
            )
        }
    }
}

@MainActor
struct FontAxisTests {

    @Test func allCasesCount() {
        #expect(FontAxis.allCases.count == 3)
    }

    @Test func weightRange() {
        let range = FontAxis.weight.range(for: .recursive)
        #expect(range == 300...1000)

        let sourceSerifRange = FontAxis.weight.range(for: .sourceSerif4)
        #expect(sourceSerifRange == 200...900)
    }

    @Test func weightDefaultValue() {
        #expect(FontAxis.weight.defaultValue(for: .recursive) == 400)
        #expect(FontAxis.weight.defaultValue(for: .sourceSerif4) == 400)
    }

    @Test func weightAxisIsUserControlled() {
        #expect(FontAxis.weight.isAutomatic == false)
    }

    @Test func casualRange() {
        let range = FontAxis.casual.range(for: .recursive)
        #expect(range == 0...1)
    }

    @Test func opticalSizeRanges() {
        let sourceSerifRange = FontAxis.opticalSize.range(for: .sourceSerif4)
        #expect(sourceSerifRange == 8...60)
    }

    @Test func defaultValues() {
        #expect(FontAxis.casual.defaultValue(for: .recursive) == 0.5)
        #expect(FontAxis.opticalSize.defaultValue(for: .sourceSerif4) == 14)
    }

    @Test func automaticAxisFlag() {
        #expect(FontAxis.casual.isAutomatic == false)
        #expect(FontAxis.opticalSize.isAutomatic == true)
    }

    @Test func labels() {
        #expect(FontAxis.casual.minLabel == "Linear")
        #expect(FontAxis.casual.maxLabel == "Casual")
        #expect(FontAxis.opticalSize.minLabel == "Small")
        #expect(FontAxis.opticalSize.maxLabel == "Large")
    }

    @Test func tags() {
        #expect(FontAxis.casual.tag == 0x4341534C)
        #expect(FontAxis.opticalSize.tag == 0x6F70737A)
    }
}

@MainActor
struct FontCategoryTests {

    @Test func allCasesCount() {
        #expect(FontCategory.allCases.count == 3)
    }

    @Test func displayNames() {
        #expect(FontCategory.sans.displayName == "Sans")
        #expect(FontCategory.serif.displayName == "Serif")
        #expect(FontCategory.mono.displayName == "Mono")
    }

    @Test func everyFamilyBelongsToExactlyOneCategory() {
        for family in FontFamily.allCases {
            let category = family.category
            #expect(FontCategory.allCases.contains(category))
        }
    }
}

@MainActor
struct FontSettingsTests {

    @Test func defaultFamilyIsSourceSerif4() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.default")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.default")
        let settings = FontSettings(defaults: defaults)
        #expect(settings.selectedFamily == .sourceSerif4)
    }

    @Test func defaultMonoFamilyIsRecursive() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.monoDefault")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.monoDefault")
        let settings = FontSettings(defaults: defaults)
        #expect(settings.selectedMonoFamily == .recursive)
    }

    @Test func selectedFamilyPersists() {
        let settings = FontSettings.shared
        let original = settings.selectedFamily

        settings.selectedFamily = .alanSans
        #expect(UserDefaults.standard.string(forKey: "fontFamily") == "alanSans")

        settings.selectedFamily = .comme
        #expect(UserDefaults.standard.string(forKey: "fontFamily") == "comme")

        settings.selectedFamily = .sourceSerif4
        #expect(UserDefaults.standard.string(forKey: "fontFamily") == "sourceSerif4")

        settings.selectedFamily = original
    }

    @Test func selectedMonoFamilyPersists() {
        let settings = FontSettings.shared
        let original = settings.selectedMonoFamily

        settings.selectedMonoFamily = .jetBrainsMono
        #expect(UserDefaults.standard.string(forKey: "monoFontFamily") == "jetBrainsMono")

        settings.selectedMonoFamily = .ibmPlexMono
        #expect(UserDefaults.standard.string(forKey: "monoFontFamily") == "ibmPlexMono")

        settings.selectedMonoFamily = .geistMono
        #expect(UserDefaults.standard.string(forKey: "monoFontFamily") == "geistMono")

        settings.selectedMonoFamily = .recursive
        #expect(UserDefaults.standard.string(forKey: "monoFontFamily") == "recursive")

        settings.selectedMonoFamily = original
    }

    @Test func monoFamilyDefaultsToRecursiveForInvalidValue() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.monoInvalid")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.monoInvalid")
        defaults.set("nonExistentFont", forKey: "monoFontFamily")
        let settings = FontSettings(defaults: defaults)
        #expect(settings.selectedMonoFamily == .recursive)
    }

    @Test func monoFamilyDefaultsToRecursiveForNonMonoFont() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.monoNonMono")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.monoNonMono")
        // Try to set a serif font as mono — should fall back to recursive
        defaults.set(FontFamily.lora.rawValue, forKey: "monoFontFamily")
        let settings = FontSettings(defaults: defaults)
        #expect(settings.selectedMonoFamily == .recursive)
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

    @Test func newSerifFontsLoadWithCorrectDefaults() {
        let defaults = UserDefaults(suiteName: "FontSettingsTests.newSerifs")!
        defaults.removePersistentDomain(forName: "FontSettingsTests.newSerifs")
        let settings = FontSettings(defaults: defaults)

        // Serif fonts with optical size should have default axis values
        #expect(settings.axisValue(for: .sourceSerif4, axis: .opticalSize) == 14)
    }
}
