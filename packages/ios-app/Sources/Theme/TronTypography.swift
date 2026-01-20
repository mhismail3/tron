import SwiftUI
import UIKit

// MARK: - Tron Typography System

/// Centralized typography definitions using Recursive variable font.
/// Fonts are created dynamically based on FontSettings.shared.casualAxis.
enum TronTypography {
    // MARK: - Font Sizes

    /// XXS - 7pt (micro text, rarely used)
    static let sizeXXS: CGFloat = 7

    /// XS - 8pt (badges, counters)
    static let sizeXS: CGFloat = 8

    /// SM - 9pt (pill labels)
    static let sizeSM: CGFloat = 9

    /// Caption - 10pt (secondary info, timestamps, small code)
    static let sizeCaption: CGFloat = 10

    /// Body2 - 11pt (file paths, code captions)
    static let sizeBody2: CGFloat = 11

    /// Body SM - 12pt (descriptions)
    static let sizeBodySM: CGFloat = 12

    /// Body3 - 13pt (compact body text)
    static let sizeBody3: CGFloat = 13

    /// Body - 14pt (standard text, messages)
    static let sizeBody: CGFloat = 14

    /// Body LG - 15pt (code blocks, input)
    static let sizeBodyLG: CGFloat = 15

    /// Title - 16pt (headings, buttons)
    static let sizeTitle: CGFloat = 16

    /// Large Title - 18pt (section headers)
    static let sizeLargeTitle: CGFloat = 18

    /// XL - 20pt (prominent headers)
    static let sizeXL: CGFloat = 20

    /// XXL - 22pt (large headers)
    static let sizeXXL: CGFloat = 22

    /// Hero - 24pt (hero text)
    static let sizeHero: CGFloat = 24

    /// Display - 32pt (display text)
    static let sizeDisplay: CGFloat = 32

    /// Timer - 56pt (large timer displays)
    static let sizeTimer: CGFloat = 56

    // MARK: - Factory Methods

    /// Create a monospace font with specified size and weight
    @MainActor
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: true
        )
    }

    /// Create a sans-serif (proportional) font with specified size and weight
    @MainActor
    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: false
        )
    }

    /// Create a UIKit monospace font with specified size and weight
    @MainActor
    static func uiFont(mono: Bool, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        TronFontLoader.createUIFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: mono
        )
    }

    // MARK: - Semantic Presets (Monospace)
    // Note: These are computed properties so they pick up current FontSettings

    /// Code blocks - Mono Regular 15pt
    @MainActor static var code: Font { mono(size: sizeBodyLG) }

    /// Chat messages - Mono Regular 14pt
    @MainActor static var messageBody: Font { mono(size: sizeBody) }

    /// Code captions, secondary code text - Mono Regular 11pt
    @MainActor static var codeCaption: Font { mono(size: sizeBody2) }

    /// Small code/metrics - Mono Regular 10pt
    @MainActor static var codeSM: Font { mono(size: sizeCaption) }

    /// Input fields - Mono Regular 15pt
    @MainActor static var input: Font { mono(size: sizeBodyLG) }

    /// File paths - Mono Medium 11pt
    @MainActor static var filePath: Font { mono(size: sizeBody2, weight: .medium) }

    /// Pill values (token counts) - Mono Medium 10pt
    @MainActor static var pillValue: Font { mono(size: sizeCaption, weight: .medium) }

    /// Timer display - Mono Bold 56pt
    @MainActor static var timerDisplay: Font { mono(size: sizeTimer, weight: .bold) }

    /// Display text - Mono SemiBold 32pt
    @MainActor static var display: Font { mono(size: sizeDisplay, weight: .semibold) }

    // MARK: - Semantic Presets (Sans)

    /// Primary buttons - Sans SemiBold 16pt
    @MainActor static var button: Font { sans(size: sizeTitle, weight: .semibold) }

    /// Compact buttons - Sans SemiBold 14pt
    @MainActor static var buttonSM: Font { sans(size: sizeBody, weight: .semibold) }

    /// Pill labels - Sans Medium 9pt
    @MainActor static var pill: Font { sans(size: sizeSM, weight: .medium) }

    /// Badge text - Sans Bold 8pt
    @MainActor static var badge: Font { sans(size: sizeXS, weight: .bold) }

    /// Caption text - Sans Regular 10pt
    @MainActor static var caption: Font { sans(size: sizeCaption) }

    /// Section headers - Sans SemiBold 16pt
    @MainActor static var headline: Font { sans(size: sizeTitle, weight: .semibold) }

    /// Subheadline - Sans Regular 14pt
    @MainActor static var subheadline: Font { sans(size: sizeBody) }

    /// Small label - Sans Medium 8pt
    @MainActor static var labelSM: Font { sans(size: sizeXS, weight: .medium) }

    /// Caption 2 (smallest) - Sans Regular 9pt
    @MainActor static var caption2: Font { sans(size: sizeSM) }

    /// Large title - Sans Bold 18pt
    @MainActor static var largeTitle: Font { sans(size: sizeLargeTitle, weight: .bold) }

    /// Body text - Sans Regular 14pt
    @MainActor static var body: Font { sans(size: sizeBody) }

    /// Small body - Sans Regular 12pt
    @MainActor static var bodySM: Font { sans(size: sizeBodySM) }
}

// MARK: - View Extension for Typography

extension View {
    /// Apply button typography
    func tronButtonFont() -> some View {
        self.font(TronTypography.button)
    }

    /// Apply code typography
    func tronCodeFont() -> some View {
        self.font(TronTypography.code)
    }

    /// Apply pill typography
    func tronPillFont() -> some View {
        self.font(TronTypography.pill)
    }

    /// Apply badge typography
    func tronBadgeFont() -> some View {
        self.font(TronTypography.badge)
    }

    /// Apply message body typography
    func tronMessageFont() -> some View {
        self.font(TronTypography.messageBody)
    }

    /// Apply input typography
    func tronInputFont() -> some View {
        self.font(TronTypography.input)
    }

    /// Apply caption typography
    func tronCaptionFont() -> some View {
        self.font(TronTypography.caption)
    }

    /// Apply headline typography
    func tronHeadlineFont() -> some View {
        self.font(TronTypography.headline)
    }

    /// Apply file path typography
    func tronFilePathFont() -> some View {
        self.font(TronTypography.filePath)
    }
}

