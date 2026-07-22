import Testing
import SwiftUI
@testable import TronMobile

@MainActor
struct AppearanceSettingsTests {

    @Test func compactChoicesUseSharedLiquidGlassStyle() throws {
        let root = iosAppRoot()
        let appearance = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Settings/Pages/AppearanceSettingsPage.swift"),
            encoding: .utf8
        )
        let tabs = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronSegmentedControl.swift"),
            encoding: .utf8
        )
        let style = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronGlassSelectionButtonStyle.swift"),
            encoding: .utf8
        )

        #expect(appearance.contains("TronGlassSelectionButtonStyle("))
        #expect(appearance.contains("GlassEffectContainer(spacing: 4)"))
        #expect(appearance.contains("GlassEffectContainer(spacing: 6)"))
        #expect(!appearance.contains(".fill(isSelected ? Color.tronEmerald"))
        #expect(tabs.contains("TronGlassSelectionButtonStyle("))
        #expect(style.contains(".glassEffect("))
    }

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

    private func iosAppRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - AppearanceSettings Persistence

    @Test func defaultModeIsDark() {
        IsolatedTestState.withDefaults(label: "appearance-default") { defaults in
            #expect(AppearanceSettings(defaults: defaults).mode == .dark)
        }
    }

    @Test func modePersistsToUserDefaults() {
        IsolatedTestState.withDefaults(label: "appearance-persistence") { defaults in
            let settings = AppearanceSettings(defaults: defaults)

            settings.mode = .light
            #expect(defaults.string(forKey: "appearanceMode") == "light")

            settings.mode = .auto
            #expect(defaults.string(forKey: "appearanceMode") == "auto")

            settings.mode = .dark
            #expect(defaults.string(forKey: "appearanceMode") == "dark")
        }
    }

}
