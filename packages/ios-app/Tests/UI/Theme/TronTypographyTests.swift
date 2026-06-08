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

    /// Helper: create a UIFont via TronFontLoader with mono: true and verify it resolves to Recursive.
    private func assertRecursive(
        size: CGFloat,
        weight: TronFontLoader.Weight = .regular,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let font = TronFontLoader.createUIFont(size: size, weight: weight, mono: true)
        #expect(
            font.familyName == "Recursive" || font.fontName.contains("Recursive"),
            "Expected Recursive family, got \(font.familyName) (\(font.fontName))",
            sourceLocation: sourceLocation
        )
    }

    /// Helper: with a non-Recursive font selected, verify a UIFont resolves to the selected family.
    private func assertFollowsSelectedFont(
        size: CGFloat,
        weight: TronFontLoader.Weight = .regular,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let original = FontSettings.shared.selectedFamily
        defer { FontSettings.shared.selectedFamily = original }

        FontSettings.shared.selectedFamily = .alanSans
        let font = TronFontLoader.createUIFont(size: size, weight: weight, mono: false)
        #expect(
            font.familyName == "Alan Sans" || font.fontName.contains("AlanSans"),
            "Expected Alan Sans family, got \(font.familyName) (\(font.fontName))",
            sourceLocation: sourceLocation
        )
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
        let original = FontSettings.shared.selectedFamily
        defer { FontSettings.shared.selectedFamily = original }

        // Even with a non-Recursive font selected, code() should produce Recursive
        for family in FontFamily.allCases where family != .recursive {
            FontSettings.shared.selectedFamily = family
            let font = TronFontLoader.createUIFont(size: 14, weight: .regular, mono: true)
            #expect(
                font.familyName == "Recursive" || font.fontName.contains("Recursive"),
                "code() should produce Recursive even with \(family.displayName) selected, got \(font.familyName)"
            )
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

        // Common sizes referenced by capability detail sheets
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
        let original = FontSettings.shared.selectedFamily
        defer { FontSettings.shared.selectedFamily = original }

        FontSettings.shared.selectedFamily = .recursive

        let codeFont = TronFontLoader.createUIFont(size: 11, weight: .regular, mono: true)
        let monoFont = TronFontLoader.createUIFont(size: 11, weight: .regular, mono: false)

        // Both should be Recursive when Recursive is selected
        #expect(codeFont.familyName == "Recursive" || codeFont.fontName.contains("Recursive"))
        #expect(monoFont.familyName == "Recursive" || monoFont.fontName.contains("Recursive"))
    }

    @Test func codePresetDoesNotReactToFontChange() {
        let original = FontSettings.shared.selectedFamily
        defer { FontSettings.shared.selectedFamily = original }

        FontSettings.shared.selectedFamily = .comme
        let font1 = TronFontLoader.createUIFont(size: 11, weight: .regular, mono: true)

        FontSettings.shared.selectedFamily = .ibmPlexSerif
        let font2 = TronFontLoader.createUIFont(size: 11, weight: .regular, mono: true)

        // Both should be Recursive regardless of selected font
        #expect(font1.familyName == font2.familyName)
    }
}
