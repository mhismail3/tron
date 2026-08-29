import Foundation
import Testing
@testable import TronMobile

@Suite("Settings row semantics")
struct SettingsRowSemanticsTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    @Test("stable secondary copy uses informational typography")
    func stableCopyIsInformational() {
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: nil,
            placement: .secondaryLine
        ) == .informational)
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: nil,
            placement: .trailing
        ) == .informational)
    }

    @Test("a separate trailing control moves the changing value to the secondary line")
    func controlledValuesUseSecondaryLine() {
        let placement = TronSettingsRowSemantics.valuePlacement(hasTrailingControl: true)
        #expect(placement == .secondaryLine)
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: "Connected",
            placement: placement
        ) == .dynamicValue)
    }

    @Test("a row without a trailing control right aligns its changing value")
    func uncontrolledValuesUseTrailingPosition() {
        let placement = TronSettingsRowSemantics.valuePlacement(hasTrailingControl: false)
        #expect(placement == .trailing)
        #expect(TronSettingsRowSemantics.secondaryRole(
            value: "GPT 5.6 Luna",
            placement: placement
        ) == .informational)
    }

    @Test("toggle stretch is local, bounded, and disabled by Reduce Motion")
    func toggleMotionPolicy() {
        #expect(TronToggleMotionPolicy.controlWidth == 50)
        #expect(TronToggleMotionPolicy.controlHeight == 30)
        #expect(TronToggleMotionPolicy.thumbScale(isStretched: false, reduceMotion: false) == 1)
        #expect(TronToggleMotionPolicy.thumbScale(isStretched: true, reduceMotion: false) > 1)
        #expect(TronToggleMotionPolicy.thumbScale(isStretched: true, reduceMotion: true) == 1)
    }

    @Test("progressive settings retain their originating accent and secondary info tone")
    func progressiveSettingsVisualTheme() throws {
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )

        #expect(settings.contains("icon: icon,\n                title: title"))
        #expect(settings.contains("accent: accent,\n                subtitleColor: .tronTextSecondary"))
        #expect(settings.contains("private func settingsDivider(accent: Color)"))
        #expect(settings.contains("destination().tronSettingsVisualTheme(accent: accent)"))
        #expect(settings.contains("accent: .tronEmerald"))
        #expect(settings.contains("accent: .tronPurple"))
        #expect(settings.contains("accent: .tronBlue"))

        #expect(presentation.contains("struct TronSettingsVisualTheme"))
        #expect(presentation.contains("informationalAccent = accent.mix(with: .tronSlate, by: 0.58)"))
        #expect(presentation.contains("settingsTheme?.informationalAccent ?? accent"))
        #expect(presentation.contains("func tronSettingsAccent("))
        #expect(presentation.contains("var usesSemanticAccent = false"))
        #expect(presentation.contains("respectsSettingsTheme: false"))
    }
}
