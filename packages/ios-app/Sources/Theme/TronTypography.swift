import SwiftUI
import UIKit

// MARK: - Tron Typography System

/// Centralized typography definitions using Recursive font family.
/// Recursive provides seamless switching between proportional (sans) and monospace variants.
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
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName: String
        switch weight {
        case .bold, .heavy, .black:
            fontName = TronFontLoader.Mono.bold
        case .semibold:
            fontName = TronFontLoader.Mono.semiBold
        case .medium:
            fontName = TronFontLoader.Mono.medium
        default:
            fontName = TronFontLoader.Mono.regular
        }
        return TronFontLoader.font(name: fontName, size: size)
    }

    /// Create a sans-serif font with specified size and weight
    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName: String
        switch weight {
        case .bold, .heavy, .black:
            fontName = TronFontLoader.Sans.bold
        case .semibold:
            fontName = TronFontLoader.Sans.semiBold
        case .medium:
            fontName = TronFontLoader.Sans.medium
        default:
            fontName = TronFontLoader.Sans.regular
        }
        return TronFontLoader.font(name: fontName, size: size)
    }

    /// Create a UIKit monospace font with specified size and weight
    static func uiFont(mono: Bool, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let fontName: String
        if mono {
            switch weight {
            case .bold, .heavy, .black:
                fontName = TronFontLoader.Mono.bold
            case .semibold:
                fontName = TronFontLoader.Mono.semiBold
            case .medium:
                fontName = TronFontLoader.Mono.medium
            default:
                fontName = TronFontLoader.Mono.regular
            }
        } else {
            switch weight {
            case .bold, .heavy, .black:
                fontName = TronFontLoader.Sans.bold
            case .semibold:
                fontName = TronFontLoader.Sans.semiBold
            case .medium:
                fontName = TronFontLoader.Sans.medium
            default:
                fontName = TronFontLoader.Sans.regular
            }
        }
        return TronFontLoader.uiFont(name: fontName, size: size)
    }

    // MARK: - Semantic Presets (Monospace)

    /// Code blocks - Mono Regular 15pt
    static let code = mono(size: sizeBodyLG)

    /// Chat messages - Mono Regular 14pt
    static let messageBody = mono(size: sizeBody)

    /// Code captions, secondary code text - Mono Regular 11pt
    static let codeCaption = mono(size: sizeBody2)

    /// Small code/metrics - Mono Regular 10pt
    static let codeSM = mono(size: sizeCaption)

    /// Input fields - Mono Regular 15pt
    static let input = mono(size: sizeBodyLG)

    /// File paths - Mono Medium 11pt
    static let filePath = mono(size: sizeBody2, weight: .medium)

    /// Pill values (token counts) - Mono Medium 10pt
    static let pillValue = mono(size: sizeCaption, weight: .medium)

    /// Timer display - Mono Bold 56pt
    static let timerDisplay = mono(size: sizeTimer, weight: .bold)

    /// Display text - Mono SemiBold 32pt
    static let display = mono(size: sizeDisplay, weight: .semibold)

    // MARK: - Semantic Presets (Sans)

    /// Primary buttons - Sans SemiBold 16pt
    static let button = sans(size: sizeTitle, weight: .semibold)

    /// Compact buttons - Sans SemiBold 14pt
    static let buttonSM = sans(size: sizeBody, weight: .semibold)

    /// Pill labels - Sans Medium 9pt
    static let pill = sans(size: sizeSM, weight: .medium)

    /// Badge text - Sans Bold 8pt
    static let badge = sans(size: sizeXS, weight: .bold)

    /// Caption text - Sans Regular 10pt
    static let caption = sans(size: sizeCaption)

    /// Section headers - Sans SemiBold 16pt
    static let headline = sans(size: sizeTitle, weight: .semibold)

    /// Subheadline - Sans Regular 14pt
    static let subheadline = sans(size: sizeBody)

    /// Small label - Sans Medium 8pt
    static let labelSM = sans(size: sizeXS, weight: .medium)

    /// Caption 2 (smallest) - Sans Regular 9pt
    static let caption2 = sans(size: sizeSM)

    /// Large title - Sans Bold 18pt
    static let largeTitle = sans(size: sizeLargeTitle, weight: .bold)

    /// Body text - Sans Regular 14pt
    static let body = sans(size: sizeBody)

    /// Small body - Sans Regular 12pt
    static let bodySM = sans(size: sizeBodySM)
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
