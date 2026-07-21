import Foundation
import Testing
import UIKit
@testable import TronMobile

// MARK: - Typography Preset Contract Tests
//
// These tests verify the semantic contract: code-family presets always produce
// Recursive Mono, while UI-family presets follow the user's selected font.

@MainActor
struct TronTypographyCodePresetTests {

    private func withSettings<T>(_ body: (FontSettings) throws -> T) rethrows -> T {
        try IsolatedTestState.withDefaults(label: "tron-typography") { defaults in
            try body(FontSettings(defaults: defaults))
        }
    }

    /// Helper: create a UIFont via TronFontLoader with mono: true and verify it resolves to Recursive.
    private func assertRecursive(
        size: CGFloat,
        weight: TronFontLoader.Weight = .regular,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        withSettings { settings in
            let font = TronFontLoader.createUIFont(
                size: size,
                weight: weight,
                mono: true,
                settings: settings
            )
            #expect(
                font.familyName == "Recursive" || font.fontName.contains("Recursive"),
                "Expected Recursive family, got \(font.familyName) (\(font.fontName))",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Helper: with a non-Recursive font selected, verify a UIFont resolves to the selected family.
    private func assertFollowsSelectedFont(
        size: CGFloat,
        weight: TronFontLoader.Weight = .regular,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        withSettings { settings in
            settings.selectedFamily = .alanSans
            let font = TronFontLoader.createUIFont(
                size: size,
                weight: weight,
                mono: false,
                settings: settings
            )
            #expect(
                font.familyName == "Alan Sans" || font.fontName.contains("AlanSans"),
                "Expected Alan Sans family, got \(font.familyName) (\(font.fontName))",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Code Presets (always Recursive Mono)

    @Test func codeBlockUsesRecursiveMono() {
        assertRecursive(size: TronTypography.sizeBodyLG)
    }

    @Test func codeContentUsesRecursiveMono() {
        assertRecursive(size: TronTypography.sizeBody2)
    }

    @Test func codeContentSMUsesRecursiveMono() {
        assertRecursive(size: TronTypography.sizeCaption)
    }

    @Test func filePathUsesSelectedFont() {
        // filePath is used broadly for notification pills and labels — follows user font
        assertFollowsSelectedFont(size: TronTypography.sizeBody2, weight: .medium)
    }

    @Test func codeFactoryAlwaysProducesRecursive() {
        withSettings { settings in
            for family in FontFamily.allCases where family != .recursive {
                settings.selectedFamily = family
                let font = TronFontLoader.createUIFont(
                    size: 14,
                    weight: .regular,
                    mono: true,
                    settings: settings
                )
                #expect(
                    font.familyName == "Recursive" || font.fontName.contains("Recursive"),
                    "code() should produce Recursive even with \(family.displayName) selected, got \(font.familyName)"
                )
            }
        }
    }

    // MARK: - UI Presets (follow selected font)

    @Test func codeCaptionUsesSelectedFont() {
        assertFollowsSelectedFont(size: TronTypography.sizeBody2)
    }

    @Test func codeSMUsesSelectedFont() {
        assertFollowsSelectedFont(size: TronTypography.sizeCaption)
    }

    @Test func monoFactoryUsesSelectedFont() {
        assertFollowsSelectedFont(size: 14)
    }

    @Test func sansFactoryUsesSelectedFont() {
        assertFollowsSelectedFont(size: 14)
    }

    // MARK: - Size Correctness

    @Test func presetSizes() {
        // Code presets
        #expect(TronTypography.sizeBodyLG == 15)  // codeBlock
        #expect(TronTypography.sizeBody2 == 11)    // codeContent, codeCaption, filePath
        #expect(TronTypography.sizeCaption == 10)   // codeContentSM, codeSM

        // Common sizes referenced by tool detail sheets
        #expect(TronTypography.sizeBodySM == 12)
        #expect(TronTypography.sizeBody == 14)
        #expect(TronTypography.sizeBody3 == 13)
        #expect(TronTypography.sizeSM == 9)
        #expect(TronTypography.sizeXS == 8)
    }

    // MARK: - Weight Variants

    @Test func codeWithWeightsProducesRecursive() {
        let weights: [TronFontLoader.Weight] = [.light, .regular, .medium, .semibold, .bold]
        for weight in weights {
            assertRecursive(size: 11, weight: weight)
        }
    }

    // MARK: - Edge Cases

    @Test func recursiveSelectedFontCodeAndMonoAreBothRecursive() {
        withSettings { settings in
            settings.selectedFamily = .recursive
            let codeFont = TronFontLoader.createUIFont(
                size: 11,
                weight: .regular,
                mono: true,
                settings: settings
            )
            let monoFont = TronFontLoader.createUIFont(
                size: 11,
                weight: .regular,
                mono: false,
                settings: settings
            )
            #expect(codeFont.familyName == "Recursive" || codeFont.fontName.contains("Recursive"))
            #expect(monoFont.familyName == "Recursive" || monoFont.fontName.contains("Recursive"))
        }
    }

    @Test func codePresetDoesNotReactToFontChange() {
        withSettings { settings in
            settings.selectedFamily = .comme
            let font1 = TronFontLoader.createUIFont(
                size: 11,
                weight: .regular,
                mono: true,
                settings: settings
            )
            settings.selectedFamily = .ibmPlexSerif
            let font2 = TronFontLoader.createUIFont(
                size: 11,
                weight: .regular,
                mono: true,
                settings: settings
            )
            #expect(font1.familyName == font2.familyName)
        }
    }
}
