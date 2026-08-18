import SwiftUI

/// Pure, conservative contrast policy for extension-provided RGB styles.
/// Admitted colors remain package-agnostic, but unreadable pairs fall back to
/// the native Tron palette rather than making the chat inaccessible.
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
        // Inverse is a color swap, not an additional foreground/background
        // modifier. Resolve the swapped pair first so contrast validation sees
        // the colors that will actually be painted.
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
        let channels = [Double((rgb >> 16) & 0xff), Double((rgb >> 8) & 0xff), Double(rgb & 0xff)].map { $0 / 255 }
        let linear = channels.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

struct ExtensionFrameView: View {
    let frame: ExtensionFrame

    private var rows: [ExtensionFrameLine] {
        frame.lines.filter { !NativeExtensionText.isDetailHint($0.plainText) && !NativeExtensionText.clean($0.plainText).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(rows.map { NativeExtensionText.clean($0.plainText) }.joined(separator: "\n")))
    }

    private func row(_ line: ExtensionFrameLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(TronTypography.sans(size: 5))
                .foregroundStyle(Color.tronCyan)
                .padding(.top, 7)
            Text(nativeText(for: line))
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func nativeText(for line: ExtensionFrameLine) -> AttributedString {
        var result = AttributedString()
        for run in line.runs {
            var segment = AttributedString(run.text)
            if let rawLink = run.style.link, let url = NativeExtensionText.safeURL(rawLink) {
                segment.link = url
            }
            result += segment
        }
        if result.characters.isEmpty {
            result = AttributedString(NativeExtensionText.clean(line.plainText))
        }
        return result
    }
}
