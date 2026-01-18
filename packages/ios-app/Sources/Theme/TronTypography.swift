import SwiftUI

// MARK: - Tron Typography System

/// Centralized typography definitions for consistent text styling
enum TronTypography {
    // MARK: - Font Sizes

    /// Extra small - 8pt (badges, counters)
    static let sizeXS: CGFloat = 8

    /// Small - 9pt (pill labels)
    static let sizeSM: CGFloat = 9

    /// Caption - 10pt (secondary info, timestamps)
    static let sizeCaption: CGFloat = 10

    /// Body small - 12pt (descriptions)
    static let sizeBodySM: CGFloat = 12

    /// Body - 14pt (standard text)
    static let sizeBody: CGFloat = 14

    /// Body large - 15pt (code, monospaced)
    static let sizeBodyLG: CGFloat = 15

    /// Title - 16pt (headings, buttons)
    static let sizeTitle: CGFloat = 16

    /// Large title - 18pt (section headers)
    static let sizeLargeTitle: CGFloat = 18

    /// Extra large - 20pt (prominent headers)
    static let sizeXL: CGFloat = 20

    // MARK: - Predefined Fonts

    /// Button text
    static let button = Font.system(size: sizeTitle, weight: .semibold)

    /// Button text (compact)
    static let buttonSM = Font.system(size: sizeBody, weight: .semibold)

    /// Code/monospaced text
    static let code = Font.system(size: sizeBodyLG, design: .monospaced)

    /// Code caption
    static let codeSM = Font.system(.subheadline, design: .monospaced)

    /// Pill label (context, model, reasoning)
    static let pill = Font.system(size: sizeSM, weight: .medium)

    /// Pill value (token counts, etc.)
    static let pillValue = Font.system(size: sizeCaption, weight: .medium, design: .monospaced)

    /// Badge text (counters, indicators)
    static let badge = Font.system(size: sizeXS, weight: .bold)

    /// Small label
    static let labelSM = Font.system(size: sizeXS, weight: .medium)

    /// Caption text
    static let caption = Font.caption

    /// Caption 2 (smallest system text)
    static let caption2 = Font.caption2

    /// Headline
    static let headline = Font.headline

    /// Subheadline
    static let subheadline = Font.subheadline
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
}
