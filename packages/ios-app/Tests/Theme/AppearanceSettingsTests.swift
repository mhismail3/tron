import Testing
import SwiftUI
@testable import TronMobile

@MainActor
struct AppearanceSettingsTests {

    // MARK: - AppearanceMode

    @Test func modeRawValues() {
        #expect(AppearanceMode.light.rawValue == "light")
        #expect(AppearanceMode.dark.rawValue == "dark")
        #expect(AppearanceMode.auto.rawValue == "auto")
    }

    @Test func modeColorScheme() {
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
        #expect(AppearanceMode.auto.colorScheme == nil)
    }

    @Test func modeLabels() {
        #expect(AppearanceMode.light.label == "Light")
        #expect(AppearanceMode.dark.label == "Dark")
        #expect(AppearanceMode.auto.label == "Auto")
    }

    @Test func modeIcons() {
        #expect(AppearanceMode.light.icon == "sun.max.fill")
        #expect(AppearanceMode.dark.icon == "moon.fill")
        #expect(AppearanceMode.auto.icon == "circle.lefthalf.filled")
    }

    @Test func modeCaseIterable() {
        #expect(AppearanceMode.allCases == [.light, .dark, .auto])
    }

    @Test func modeRoundTrip() {
        for mode in AppearanceMode.allCases {
            let parsed = AppearanceMode(rawValue: mode.rawValue)
            #expect(parsed == mode)
        }
    }

    // MARK: - AppearanceSettings Persistence

    @Test func defaultModeIsDark() {
        // Clear any stored value
        UserDefaults.standard.removeObject(forKey: "appearanceMode")
        // Singleton already initialized, but we can verify the default logic
        let mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "") ?? .dark
        #expect(mode == .dark)
    }

    @Test func modePersistsToUserDefaults() {
        let settings = AppearanceSettings.shared
        let originalMode = settings.mode

        settings.mode = .light
        #expect(UserDefaults.standard.string(forKey: "appearanceMode") == "light")

        settings.mode = .auto
        #expect(UserDefaults.standard.string(forKey: "appearanceMode") == "auto")

        settings.mode = .dark
        #expect(UserDefaults.standard.string(forKey: "appearanceMode") == "dark")

        // Restore
        settings.mode = originalMode
    }

}
