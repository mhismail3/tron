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

private struct ExtensionFrameLineLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + min(size.width, width)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders an already-admitted extension frame without interpreting package
/// identity or terminal control sequences. Interactive surface kinds are
/// deliberately excluded from this first native pass.
struct ExtensionFrameView: View {
    let frame: ExtensionFrame
    @Environment(\.colorScheme) private var colorScheme

    private var nativeBackground: String { colorScheme == .dark ? "090A0C" : "F7F8FA" }
    private var nativeForeground: String { colorScheme == .dark ? "F8FAFC" : "111827" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(frame.lines.enumerated()), id: \.offset) { _, line in
                if !NativeExtensionText.isDetailHint(line.plainText) { lineView(line) }
            }
        }
        .font(TronTypography.bodySM)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(frame.lines.filter { !NativeExtensionText.isDetailHint($0.plainText) }.map { NativeExtensionText.clean($0.plainText) }.joined(separator: "\n")))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineView(_ line: ExtensionFrameLine) -> some View {
        ExtensionFrameLineLayout(spacing: 0) {
            ForEach(Array(line.runs.enumerated()), id: \.offset) { _, run in
                styledText(run)
            }
        }
    }

    private func styledText(_ run: ExtensionFrameRun) -> AnyView {
        let style = run.style
        let colors = ExtensionFrameColorPolicy.resolvedColors(
            foreground: style.foreground,
            background: style.background,
            inverse: style.inverse == true,
            nativeForeground: nativeForeground,
            nativeBackground: nativeBackground,
            fallbackBackground: colorScheme == .dark ? "16181D" : "FFFFFF"
        )
        var content = AnyView(Text(run.text).foregroundColor(Color(hex: colors.foreground)))
        if style.bold == true { content = AnyView(content.bold()) }
        if style.italic == true { content = AnyView(content.italic()) }
        if style.underline == true { content = AnyView(content.underline()) }
        if style.strike == true { content = AnyView(content.strikethrough()) }
        // Dim is intentionally not represented with opacity: it can reduce an
        // otherwise admitted 4.5:1 pair below accessible contrast.
        content = AnyView(content.background(Color(hex: colors.background)))
        if let link = style.link, let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
            content = AnyView(Link(destination: url) { content }.accessibilityLabel("Link: \(run.text)"))
        }
        return content
    }
}
