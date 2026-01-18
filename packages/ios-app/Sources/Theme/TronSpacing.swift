import SwiftUI

// MARK: - Tron Spacing System

/// Centralized spacing and dimension definitions for consistent layout
enum TronSpacing {
    // MARK: - Base Spacing Scale (4px increments)

    /// 2pt - minimal spacing
    static let xxs: CGFloat = 2

    /// 4pt - tight spacing
    static let xs: CGFloat = 4

    /// 6pt - compact spacing
    static let sm: CGFloat = 6

    /// 8pt - standard small spacing
    static let md: CGFloat = 8

    /// 10pt - medium spacing
    static let lg: CGFloat = 10

    /// 12pt - standard spacing
    static let xl: CGFloat = 12

    /// 14pt - comfortable spacing
    static let xxl: CGFloat = 14

    /// 16pt - section spacing
    static let section: CGFloat = 16

    /// 20pt - large spacing
    static let large: CGFloat = 20

    /// 24pt - extra large spacing
    static let xlarge: CGFloat = 24

    // MARK: - Component-Specific Spacing

    /// Message bubble padding
    static let bubblePadding: CGFloat = 12

    /// Input field horizontal padding
    static let inputHorizontal: CGFloat = 14

    /// Input field vertical padding
    static let inputVertical: CGFloat = 10

    /// Input bar horizontal margins
    static let inputBarMargin: CGFloat = 16

    /// Input bar bottom padding
    static let inputBarBottom: CGFloat = 8

    /// Status pill internal spacing
    static let pillSpacing: CGFloat = 4

    /// Content area item spacing
    static let contentSpacing: CGFloat = 8

    /// Tool stagger item spacing
    static let toolSpacing: CGFloat = 8

    // MARK: - Corner Radii

    /// Small radius - pills, badges
    static let cornerSM: CGFloat = 6

    /// Medium radius - buttons, small cards
    static let cornerMD: CGFloat = 10

    /// Large radius - cards, containers
    static let cornerLG: CGFloat = 16

    /// Input field radius
    static let cornerInput: CGFloat = 18

    /// Extra large radius - input bar glass effect
    static let cornerXL: CGFloat = 20

    /// Full rounded - circles
    static let cornerFull: CGFloat = 999

    // MARK: - Icon Sizes

    /// Small icon size
    static let iconSM: CGFloat = 14

    /// Medium icon size
    static let iconMD: CGFloat = 16

    /// Large icon size
    static let iconLG: CGFloat = 20

    /// Extra large icon size
    static let iconXL: CGFloat = 24

    // MARK: - Line/Border Widths

    /// Thin border
    static let borderThin: CGFloat = 0.5

    /// Standard border
    static let borderStandard: CGFloat = 1

    /// Medium border
    static let borderMedium: CGFloat = 1.5

    /// Thick border
    static let borderThick: CGFloat = 2
}

// MARK: - Padding Convenience Extensions

extension View {
    /// Apply standard horizontal section padding
    func tronHorizontalPadding() -> some View {
        self.padding(.horizontal, TronSpacing.section)
    }

    /// Apply standard content spacing
    func tronContentPadding() -> some View {
        self.padding(TronSpacing.bubblePadding)
    }

    /// Apply input field padding
    func tronInputPadding() -> some View {
        self
            .padding(.horizontal, TronSpacing.inputHorizontal)
            .padding(.vertical, TronSpacing.inputVertical)
    }
}
