import SwiftUI
import UIKit

// MARK: - Tron Typography System

/// Centralized typography definitions.
/// All text uses the user-selected font family from FontSettings.
/// Code blocks and file paths always use Recursive Mono.
enum TronTypography {
    // MARK: - Font Sizes

    /// XXS - 7pt (micro text, rarely used)
    static let sizeXXS: CGFloat = 7

    /// XS - 8pt (badges, counters)
    static let sizeXS: CGFloat = 8

    /// SM - 9pt (pill labels)
    static let sizeSM: CGFloat = 9

    /// Caption - 10pt (secondary info, timestamps)
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

    /// Create a font in the user-selected family
    @MainActor
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: false
        )
    }

    /// Create a font in the user-selected family (alias for mono)
    @MainActor
    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: false
        )
    }

    /// Create a Recursive Mono font — only for actual code content
    @MainActor
    static func code(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TronFontLoader.createFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: true
        )
    }

    /// Create a UIKit font in the user-selected family
    @MainActor
    static func uiFont(mono: Bool, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        TronFontLoader.createUIFont(
            size: size,
            weight: TronFontLoader.weight(from: weight),
            mono: mono
        )
    }

    // MARK: - Semantic Presets (Code — always Recursive Mono)

    /// Code blocks - 15pt (only preset that forces Recursive Mono)
    @MainActor static var codeBlock: Font { code(size: sizeBodyLG) }

    // MARK: - Semantic Presets (Selected Font)

    /// Secondary text, captions - 11pt
    @MainActor static var codeCaption: Font { mono(size: sizeBody2) }

    /// Small metrics text - 10pt
    @MainActor static var codeSM: Font { mono(size: sizeCaption) }

    /// File paths - Medium 11pt
    @MainActor static var filePath: Font { mono(size: sizeBody2, weight: .medium) }

    /// Pill values (token counts) - Medium 10pt
    @MainActor static var pillValue: Font { mono(size: sizeCaption, weight: .medium) }

    /// Timer display - Bold 56pt
    @MainActor static var timerDisplay: Font { mono(size: sizeTimer, weight: .bold) }

    // MARK: - Semantic Presets (Selected Font)

    /// Chat messages - 14pt
    @MainActor static var messageBody: Font { mono(size: sizeBody) }

    /// Input fields - 15pt
    @MainActor static var input: Font { mono(size: sizeBodyLG) }

    /// Display text - SemiBold 32pt
    @MainActor static var display: Font { mono(size: sizeDisplay, weight: .semibold) }

    /// Primary buttons - SemiBold 16pt
    @MainActor static var button: Font { sans(size: sizeTitle, weight: .semibold) }

    /// Compact buttons - SemiBold 14pt
    @MainActor static var buttonSM: Font { sans(size: sizeBody, weight: .semibold) }

    /// Pill labels - Medium 9pt
    @MainActor static var pill: Font { sans(size: sizeSM, weight: .medium) }

    /// Badge text - Bold 8pt
    @MainActor static var badge: Font { sans(size: sizeXS, weight: .bold) }

    /// Caption text - Regular 10pt
    @MainActor static var caption: Font { sans(size: sizeCaption) }

    /// Section headers - SemiBold 16pt
    @MainActor static var headline: Font { sans(size: sizeTitle, weight: .semibold) }

    /// Subheadline - Regular 14pt
    @MainActor static var subheadline: Font { sans(size: sizeBody) }

    /// Small label - Medium 8pt
    @MainActor static var labelSM: Font { sans(size: sizeXS, weight: .medium) }

    /// Caption 2 (smallest) - Regular 9pt
    @MainActor static var caption2: Font { sans(size: sizeSM) }

    /// Large title - Bold 18pt
    @MainActor static var largeTitle: Font { sans(size: sizeLargeTitle, weight: .bold) }

    /// Body text - Regular 14pt
    @MainActor static var body: Font { sans(size: sizeBody) }

    /// Small body - Regular 12pt
    @MainActor static var bodySM: Font { sans(size: sizeBodySM) }
}

// MARK: - View Extension for Typography

extension View {
    func tronButtonFont() -> some View {
        self.font(TronTypography.button)
    }

    func tronCodeFont() -> some View {
        self.font(TronTypography.codeBlock)
    }

    func tronPillFont() -> some View {
        self.font(TronTypography.pill)
    }

    func tronBadgeFont() -> some View {
        self.font(TronTypography.badge)
    }

    func tronMessageFont() -> some View {
        self.font(TronTypography.messageBody)
    }

    func tronInputFont() -> some View {
        self.font(TronTypography.input)
    }

    func tronCaptionFont() -> some View {
        self.font(TronTypography.caption)
    }

    func tronHeadlineFont() -> some View {
        self.font(TronTypography.headline)
    }

    func tronFilePathFont() -> some View {
        self.font(TronTypography.filePath)
    }
}
