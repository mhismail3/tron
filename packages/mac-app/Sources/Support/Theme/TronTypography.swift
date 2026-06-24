import CoreGraphics
import SwiftUI

/// Mac onboarding typography tokens.
///
/// The face is bundled from Google Fonts so the compact 480pt Mac
/// wizard keeps the same look on clean machines and dogfood builds.
enum TronTypography {
    static let titleSize: CGFloat = 22
    static let bodySize: CGFloat = 15
    static let subheadlineSize: CGFloat = 13
    static let captionSize: CGFloat = 11
    static let codeCaptionSize: CGFloat = 10
    static let buttonSize: CGFloat = 14
    static let progressSize: CGFloat = 12

    static var wizardTitle: Font { sans(size: titleSize, weight: .semibold) }
    static var wizardBody: Font { sans(size: bodySize, weight: .regular) }
    static var wizardBodySmall: Font { sans(size: subheadlineSize, weight: .regular) }
    static var wizardHeadline: Font { sans(size: bodySize, weight: .semibold) }
    static var wizardSubheadline: Font { sans(size: subheadlineSize, weight: .semibold) }
    static var wizardCaption: Font { sans(size: captionSize, weight: .regular) }
    static var wizardCaptionStrong: Font { sans(size: captionSize, weight: .semibold) }
    static var wizardButton: Font { sans(size: buttonSize, weight: .semibold) }
    static var wizardSecondaryButton: Font { sans(size: buttonSize, weight: .medium) }
    static var wizardProgress: Font { sans(size: progressSize, weight: .medium) }
    static var wizardCodeCaption: Font { .system(size: codeCaptionSize, design: .monospaced) }
    static var wizardCodeValue: Font { .system(size: subheadlineSize, design: .monospaced) }

    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(TronFontLoader.bundledSansFamilyName, size: size)
            .weight(weight)
    }
}
