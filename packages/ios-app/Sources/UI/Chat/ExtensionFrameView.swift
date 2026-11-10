import SwiftUI
import TronMobileCore

struct ExtensionFrameRunPresentation {
    let text: String
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let isStrikethrough: Bool
    let foregroundHex: String?
    let link: URL?
    let isDim: Bool
    let usesSecondaryForeground: Bool

    struct NativePalette {
        let foreground: String
        let background: String

        init(colorScheme: ColorScheme) {
            switch colorScheme {
            case .dark:
                foreground = "E8E9EA"
                background = "0D0E0F"
            default:
                foreground = "111827"
                background = "F7F8FA"
            }
        }
    }

    init(run: ExtensionFrameRun, palette: NativePalette) {
        text = run.text
        let style = run.style
        let resolved = ExtensionFrameColorPolicy.resolvedColors(
            foreground: style.foreground,
            background: style.background,
            inverse: style.inverse == true,
            nativeForeground: palette.foreground,
            nativeBackground: palette.background,
            fallbackBackground: palette.background
        )
        let requestedForeground = style.foreground != nil || style.background != nil || style.inverse == true
        foregroundHex = requestedForeground ? resolved.foreground : nil
        isBold = style.bold == true
        isItalic = style.italic == true
        isUnderline = style.underline == true
        isStrikethrough = style.strike == true
        isDim = style.dim == true
        usesSecondaryForeground = style.dim == true && !requestedForeground
        link = style.link.flatMap(NativeExtensionText.safeURL)
    }
}

enum ExtensionFrameColorPolicy {
    static let minimumContrast: Double = 4.5

    static func usableForeground(_ hex: String?, background: String, fallback: String) -> String {
        guard let hex, contrastRatio(hex, background) >= minimumContrast else { return fallback }
        return hex
    }

    static func usableBackground(_ hex: String?, foreground: String, fallback: String) -> String {
        guard let hex, contrastRatio(foreground, hex) >= minimumContrast else { return fallback }
        return hex
    }

    static func resolvedColors(
        foreground: String?,
        background: String?,
        inverse: Bool,
        nativeForeground: String,
        nativeBackground: String,
        fallbackBackground: String
    ) -> (foreground: String, background: String) {
        let requestedForeground = inverse ? (background ?? nativeBackground) : (foreground ?? nativeForeground)
        let requestedBackground = inverse ? (foreground ?? nativeForeground) : (background ?? nativeBackground)
        let safeBackground = usableBackground(
            requestedBackground,
            foreground: requestedForeground,
            fallback: fallbackBackground
        )
        let safeForeground = usableForeground(
            requestedForeground,
            background: safeBackground,
            fallback: nativeForeground
        )
        return (safeForeground, safeBackground)
    }

    static func contrastRatio(_ first: String, _ second: String) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        let light = max(firstLuminance, secondLuminance)
        let dark = min(firstLuminance, secondLuminance)
        return (light + 0.05) / (dark + 0.05)
    }

    private static func luminance(_ value: String) -> Double {
        let cleaned = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let rgb = Int(cleaned, radix: 16) else { return 0.5 }
        let channels: [Double] = [Double((rgb >> 16) & 0xff), Double((rgb >> 8) & 0xff), Double(rgb & 0xff)].map { $0 / 255 }
        let linear: [Double] = channels.map { (channel: Double) -> Double in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let red: Double = 0.2126 * linear[0]
        let green: Double = 0.7152 * linear[1]
        let blue: Double = 0.0722 * linear[2]
        return red + green + blue
    }
}

struct ExtensionFrameView: View {
    let frame: ExtensionFrame
    @Environment(\.colorScheme) private var colorScheme

    private var preparedRows: [PreparedRow] {
        let palette = ExtensionFrameRunPresentation.NativePalette(colorScheme: colorScheme)
        return frame.lines.compactMap { line in
            let plain = NativeExtensionText.clean(line.plainText)
            guard !plain.isEmpty else { return nil }
            return PreparedRow(attributed: nativeText(for: line, palette: palette), plain: plain)
        }
    }

    var body: some View {
        let rows = preparedRows
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                self.row(row.attributed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(rows.map(\.plain).joined(separator: "\n")))
    }

    private struct PreparedRow {
        let attributed: AttributedString
        let plain: String
    }

    private func row(_ attributed: AttributedString) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(TronTypography.sans(size: 5))
                .foregroundStyle(Color.tronCyan)
                .padding(.top, 7)
            Text(attributed)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func nativeText(for line: ExtensionFrameLine, palette: ExtensionFrameRunPresentation.NativePalette) -> AttributedString {
        var result = AttributedString()
        for run in line.runs {
            let presentation = ExtensionFrameRunPresentation(run: run, palette: palette)
            var segment = AttributedString(presentation.text)
            var intents: InlinePresentationIntent = []
            if presentation.isBold { intents.insert(.stronglyEmphasized) }
            if presentation.isItalic { intents.insert(.emphasized) }
            if !intents.isEmpty { segment.inlinePresentationIntent = intents }
            if presentation.isUnderline { segment.underlineStyle = .single }
            if presentation.isStrikethrough { segment.strikethroughStyle = .single }
            if let hex = presentation.foregroundHex {
                segment.foregroundColor = Color(hex: hex)
            } else if presentation.usesSecondaryForeground {
                segment.foregroundColor = Color.tronTextSecondary
            }
            if let url = presentation.link { segment.link = url }
            result += segment
        }
        if result.characters.isEmpty {
            result = AttributedString(NativeExtensionText.clean(line.plainText))
        }
        return result
    }
}
