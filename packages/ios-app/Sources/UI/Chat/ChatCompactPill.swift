import SwiftUI
import UIKit

@MainActor
extension ChatNotificationTone {
    /// Small compact-pill text uses contrast-safe foregrounds independently of
    /// the brighter semantic surface tint.
    var primaryColor: Color {
        switch self {
        case .accent: .tronAccentText
        case .command: ChatCompactPillPalette.commandPrimary
        case .tool: .tronAccentText
        case .information: ChatCompactPillPalette.informationPrimary
        case .purple: ChatCompactPillPalette.purplePrimary
        case .subagent: ChatCompactPillPalette.subagentPrimary
        case .warning: ChatCompactPillPalette.warningPrimary
        case .error: .tronError
        case .neutral: ChatCompactPillPalette.neutralPrimary
        }
    }

    var secondaryColor: Color {
        switch self {
        case .accent: ChatCompactPillPalette.accentSecondary
        case .command: ChatCompactPillPalette.commandSecondary
        case .tool: ChatCompactPillPalette.accentSecondary
        case .information: ChatCompactPillPalette.informationSecondary
        case .purple: ChatCompactPillPalette.purpleSecondary
        case .subagent: ChatCompactPillPalette.subagentSecondary
        case .warning: ChatCompactPillPalette.warningSecondary
        case .error: ChatCompactPillPalette.errorSecondary
        case .neutral: ChatCompactPillPalette.neutralSecondary
        }
    }

    var surfaceColor: Color {
        switch self {
        case .accent: .tronEmerald
        case .command: .tronIndigo
        case .tool: .tronEmerald
        case .information: .tronBlue
        case .purple: .tronPurple
        case .subagent: .tronSubagent
        case .warning: .tronAmber
        case .error: .tronError
        case .neutral: .tronSlate
        }
    }
}

/// Compact-pill foregrounds are built once: tone colors are read in transcript
/// and tool-row bodies, and a fresh dynamic color per read re-parses its hex.
private enum ChatCompactPillPalette {
    static let commandPrimary = Color(lightHex: "#4338CA", darkHex: "#C7D2FE")
    static let informationPrimary = Color(lightHex: "#0369A1", darkHex: "#38BDF8")
    static let purplePrimary = Color(lightHex: "#6D28D9", darkHex: "#C4B5FD")
    static let subagentPrimary = Color(lightHex: "#006657", darkHex: "#5DE0CE")
    static let warningPrimary = Color(lightHex: "#92400E", darkHex: "#FBBF24")
    static let neutralPrimary = Color(lightHex: "#475569", darkHex: "#CBD5E1")

    static let accentSecondary = Color(lightHex: "#047857", darkHex: "#A7F3D0")
    static let commandSecondary = Color(lightHex: "#3730A3", darkHex: "#E0E7FF")
    static let informationSecondary = Color(lightHex: "#075985", darkHex: "#7DD3FC")
    static let purpleSecondary = Color(lightHex: "#5B21B6", darkHex: "#DDD6FE")
    static let subagentSecondary = Color(lightHex: "#00594D", darkHex: "#A0EFE3")
    static let warningSecondary = Color(lightHex: "#78350F", darkHex: "#FDE68A")
    static let errorSecondary = Color(lightHex: "#991B1B", darkHex: "#FCA5A5")
    static let neutralSecondary = Color(lightHex: "#334155", darkHex: "#E2E8F0")
}

/// Stable semantic palette for compact transcript chrome. Producer identity is
/// text; category owns color, and warning/error may override that category.
enum ChatSemanticPillRole: Hashable, Sendable {
    case command
    case prompt
    case context
    case tool
    case notification

    var tone: ChatNotificationTone {
        switch self {
        case .command: .command
        case .prompt: .purple
        case .context: .purple
        case .tool: .tool
        case .notification: .information
        }
    }

    @MainActor var accent: Color { tone.surfaceColor }

    var label: String {
        switch self {
        case .command: "Command"
        case .prompt: "Prompt"
        case .context: "Context"
        case .tool: "Tool"
        case .notification: "Notification"
        }
    }
}

struct ChatCompactPillTitleMeasurement: Equatable {
    let renderedWidth: CGFloat
    let intrinsicWidth: CGFloat

    var isTruncated: Bool {
        intrinsicWidth > renderedWidth + 0.5
    }
}

struct ChatCompactPillTitleMeasurementKey: PreferenceKey {
    static let defaultValue: [ChatCompactPillTitleMeasurement] = []

    static func reduce(value: inout [ChatCompactPillTitleMeasurement], nextValue: () -> [ChatCompactPillTitleMeasurement]) {
        value.append(contentsOf: nextValue())
    }
}

enum ChatCompactPillLayoutPolicy {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    /// Matches the compact metadata-pill gap between the icon's visible edge
    /// and its label. Every chat pill/chip uses this one leading rhythm.
    static let itemSpacing: CGFloat = 5
    static let standardIconSize: CGFloat = 13
    static let toolIconSize: CGFloat = 13
    static let progressIconSize: CGFloat = 13
    static let runningToolPulseOffsetX: CGFloat = -1
    static let errorCornerRadius: CGFloat = 18
    static let capsuleCornerRadius: CGFloat = 999

    static func cornerRadius(for tone: ChatNotificationTone) -> CGFloat {
        tone == .error ? errorCornerRadius : capsuleCornerRadius
    }
}

/// Shared visual primitive for compact transcript activity. Alignment and
/// interaction remain with the role-specific owner; this type owns only shape,
/// spacing, material, and state crossfades.
struct ChatCompactPillSurface<Content: View>: View {
    let tone: ChatNotificationTone
    let material: ChatNotificationMaterial
    let interactive: Bool
    let accentOverride: Color?
    let cornerRadiusOverride: CGFloat?
    let verticalPadding: CGFloat
    @ViewBuilder let content: Content

    init(
        tone: ChatNotificationTone,
        material: ChatNotificationMaterial,
        interactive: Bool = false,
        accentOverride: Color? = nil,
        cornerRadiusOverride: CGFloat? = nil,
        verticalPadding: CGFloat = ChatCompactPillLayoutPolicy.verticalPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.tone = tone
        self.material = material
        self.interactive = interactive
        self.accentOverride = accentOverride
        self.cornerRadiusOverride = cornerRadiusOverride
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadiusOverride
                ?? ChatCompactPillLayoutPolicy.cornerRadius(for: tone),
            style: .continuous
        )
        let surfaceAccent = accentOverride ?? tone.surfaceColor
        let isGlass = material == .glass
        // One structure at every material: a value change from flat to glass
        // must not remount the pill (a remount showed the flat frame before the
        // measured glass one). The unused half of each pair is inert — a clear
        // background and stroke, or an identity glass effect.
        content
            .padding(.horizontal, ChatCompactPillLayoutPolicy.horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(shape)
            .background(surfaceAccent.opacity(isGlass ? 0 : 0.10), in: shape)
            .overlay(shape.stroke(surfaceAccent.opacity(isGlass ? 0 : 0.30), lineWidth: 0.5))
            .glassEffect(
                isGlass
                    ? .regular.tint(surfaceAccent.opacity(0.18)).interactive(interactive)
                    : .identity,
                in: shape
            )
    }
}

private struct ChatCompactPillInteractionModifier: ViewModifier {
    let accessibilityLabel: String
    let accessibilityValue: String?
    /// Whether the pill is a control. A pill that owns no action keeps its own
    /// accessibility element and label without the button trait.
    let addsButtonTrait: Bool
    /// The pill's own action, or nil for an informational pill. The interactive
    /// half is attached at every value: a conditional here switched the pill's
    /// structure and re-showed its flat frame across the truncation measurement
    /// (F10, measured as two pill instances for one notice). A pill that owns no
    /// action instead declares that it does not respond to user interaction, so
    /// no activation is offered for a control the reader cannot act on.
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content
            // The interactive glass surface remains the only visual press
            // owner. A wrapping Button would add a second touch-down phase.
            .onTapGesture { action?() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue ?? "")
            .accessibilityAddTraits(addsButtonTrait ? .isButton : [])
            .accessibilityAction { action?() }
            .accessibilityRespondsToUserInteraction(action != nil)
    }
}

extension View {
    func chatCompactPillInteraction(
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        addsButtonTrait: Bool = true,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(ChatCompactPillInteractionModifier(
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            addsButtonTrait: addsButtonTrait,
            action: action
        ))
    }
}

enum ChatToolChipShapePolicy {
    /// Status and failure tint changes are shallow. The Liquid Glass geometry
    /// never switches shape while a mounted tool run settles.
    static let cornerRadius = ChatCompactPillLayoutPolicy.capsuleCornerRadius
}

enum ChatCompactPillDetailStyle {
    case status
    case summary
}

/// A shallow animation key: transitions never compare raw request/result JSON,
/// output bodies, or summary payloads on the render path.
struct ChatCompactPillVisualState: Hashable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let icon: String
    let tone: ChatNotificationTone
    let material: ChatNotificationMaterial
    let showsProgress: Bool
    let count: Int

    init(
        id: String,
        title: String,
        detail: String?,
        icon: String,
        tone: ChatNotificationTone,
        material: ChatNotificationMaterial,
        showsProgress: Bool,
        count: Int = 1
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tone = tone
        self.material = material
        self.showsProgress = showsProgress
        self.count = count
    }

    static func toolRun(_ run: ChatToolRunPresentation) -> Self {
        let tone: ChatNotificationTone = run.failureCount > 0
            ? .error : run.isRunning ? .warning : ChatSemanticPillRole.tool.tone
        let single = run.displayCount == 1 ? run.tools.first : nil
        return Self(
            id: run.id,
            title: run.title,
            detail: single.map { tool in
                tool.toolName == "codemode" && tool.nestedCallCount > 0
                    ? run.status
                    : ComposerResourceNameFormatter.friendly(tool.subtitle)
            } ?? run.status,
            icon: run.failureCount > 0
                ? "exclamationmark.triangle.fill"
                : single.map { ToolDetailPresentation.icon(for: $0.toolName ?? $0.title) }
                    ?? "square.stack.3d.up",
            tone: tone,
            material: .glass,
            showsProgress: run.isRunning,
            count: run.displayCount
        )
    }
}

struct ChatToolChipTransitionState: Equatable, Sendable {
    private(set) var token = 0
    private(set) var target: ChatCompactPillVisualState?

    mutating func retarget(_ value: ChatCompactPillVisualState) -> Int {
        token &+= 1
        target = value
        return token
    }

    func admits(_ candidate: Int) -> Bool { candidate == token }
}

struct ChatCompactPillLeadingIcon: View {
    let icon: String
    let accent: Color
    let showsProgress: Bool
    let iconSize: CGFloat
    let progressOffsetX: CGFloat

    init(
        icon: String,
        accent: Color,
        showsProgress: Bool = false,
        iconSize: CGFloat = ChatCompactPillLayoutPolicy.standardIconSize,
        progressOffsetX: CGFloat = 0
    ) {
        self.icon = icon
        self.accent = accent
        self.showsProgress = showsProgress
        self.iconSize = iconSize
        self.progressOffsetX = progressOffsetX
    }

    var body: some View {
        ZStack {
            if showsProgress {
                TronPulseLoadingIndicator(
                    accent: accent,
                    size: ChatCompactPillLayoutPolicy.progressIconSize
                )
                .offset(x: progressOffsetX)
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
            } else {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: iconSize, weight: .semibold))
                    .foregroundStyle(accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        // Keep vertical pill geometry stable without reserving horizontal
        // whitespace between the symbol's visible edge and its label.
        .frame(minHeight: max(iconSize, ChatCompactPillLayoutPolicy.progressIconSize))
        .accessibilityHidden(true)
    }
}

struct ChatCompactPillLabel<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String?
    let tone: ChatNotificationTone
    let showsProgress: Bool
    let iconSize: CGFloat
    let progressOffsetX: CGFloat
    let titleWeight: Font.Weight
    let detailStyle: ChatCompactPillDetailStyle
    let foregroundOverride: Color?
    @ViewBuilder let trailing: Trailing

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        tone: ChatNotificationTone,
        showsProgress: Bool = false,
        iconSize: CGFloat = ChatCompactPillLayoutPolicy.standardIconSize,
        progressOffsetX: CGFloat = 0,
        titleWeight: Font.Weight = .bold,
        detailStyle: ChatCompactPillDetailStyle = .status,
        foregroundOverride: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.tone = tone
        self.showsProgress = showsProgress
        self.iconSize = iconSize
        self.progressOffsetX = progressOffsetX
        self.titleWeight = titleWeight
        self.detailStyle = detailStyle
        self.foregroundOverride = foregroundOverride
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
            ChatCompactPillLeadingIcon(
                icon: icon,
                accent: foregroundOverride ?? tone.primaryColor,
                showsProgress: showsProgress,
                iconSize: iconSize,
                progressOffsetX: progressOffsetX
            )
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: titleWeight))
                .foregroundStyle(foregroundOverride ?? tone.primaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatCompactPillTitleMeasurementKey.self,
                            value: [ChatCompactPillTitleMeasurement(
                                renderedWidth: proxy.size.width,
                                intrinsicWidth: 0
                            )]
                        )
                    }
                }
                .overlay(alignment: .leading) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: titleWeight))
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ChatCompactPillTitleMeasurementKey.self,
                                    value: [ChatCompactPillTitleMeasurement(
                                        renderedWidth: 0,
                                        intrinsicWidth: proxy.size.width
                                    )]
                                )
                            }
                        }
                }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(detailStyle == .summary
                        ? TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium)
                        : TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(detailStyle == .summary
                        ? Color.tronTextSecondary : (foregroundOverride ?? tone.secondaryColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            trailing
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

extension ChatCompactPillLabel where Trailing == EmptyView {
    init(
        icon: String,
        title: String,
        detail: String? = nil,
        tone: ChatNotificationTone,
        showsProgress: Bool = false,
        iconSize: CGFloat = ChatCompactPillLayoutPolicy.standardIconSize,
        progressOffsetX: CGFloat = 0,
        titleWeight: Font.Weight = .bold,
        detailStyle: ChatCompactPillDetailStyle = .status,
        foregroundOverride: Color? = nil
    ) {
        self.init(
            icon: icon,
            title: title,
            detail: detail,
            tone: tone,
            showsProgress: showsProgress,
            iconSize: iconSize,
            progressOffsetX: progressOffsetX,
            titleWeight: titleWeight,
            detailStyle: detailStyle,
            foregroundOverride: foregroundOverride,
            trailing: { EmptyView() }
        )
    }
}

enum ChatPromptContainerStyle {
    static let cornerRadius: CGFloat = 18
    static let horizontalPadding: CGFloat = 12
    static let topPadding: CGFloat = 8
    static let userPromptBottomPadding: CGFloat = 8
    static let queuedMessageBottomPadding: CGFloat = 12
    static let tintOpacity: Double = 0.16
}

enum UserPromptTextLayoutPolicy {
    static let maximumWidth: CGFloat = 364 // 30% narrower than the prior 520-point bound.
    static let fontScale: CGFloat = 1

    static func fittedWidth(measured: CGFloat, proposed: CGFloat) -> CGFloat {
        min(max(0, measured), max(0, proposed))
    }

    /// Chooses one stable intrinsic-or-wrapped container width. Flexible
    /// children (for example a queued-card header spacer) receive only this
    /// resolved proposal and therefore cannot expand every short card to the cap.
    static func boundedContainerWidth(
        intrinsic: CGFloat,
        proposed: CGFloat,
        maximum: CGFloat = maximumWidth
    ) -> CGFloat {
        let available = min(max(0, proposed), max(0, maximum))
        guard intrinsic.isFinite, intrinsic > 0, intrinsic <= available else {
            return available
        }
        return intrinsic
    }

    /// The prompt block remains right-anchored by SwiftUI. Lines read from the
    /// logical leading edge inside that narrower block instead of stretching
    /// inter-word spacing to full justification.
    static func alignment(layoutDirection: LayoutDirection) -> NSTextAlignment {
        layoutDirection == .rightToLeft ? .right : .left
    }
}

enum UserPromptTextTone: Hashable {
    case user
    case automation

    var color: Color {
        switch self {
        case .user: .userMessageText
        case .automation: .tronAutomationText
        }
    }
}

/// UIKit/TextKit retains deterministic wrapping and Dynamic Type while SwiftUI
/// owns the narrower right-anchored prompt block.
struct UserPromptText: View {
    let text: String
    var tone: UserPromptTextTone = .user
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        // Reading the selected family and axes makes Observation invalidate this
        // wrapper when the app's live typography settings change.
        let family = fontSettings.selectedFamily
        let weight = fontSettings.axisValue(for: family, axis: .weight)
        let casual = fontSettings.axisValue(for: family, axis: .casual)
        UserPromptLabel(
            text: text,
            tone: tone,
            fontRevision: "\(family.rawValue):\(weight):\(casual)"
        )
        .accessibilityLabel(text)
    }
}

private struct UserPromptLabel: UIViewRepresentable {
    final class Coordinator {
        var text: String?
        var tone: UserPromptTextTone?
        var fontRevision: String?
        var sizeCategory: ContentSizeCategory?
        var layoutDirection: LayoutDirection?
        var preferredContentSizeCategory: UIContentSizeCategory?
        var interfaceStyle: UIUserInterfaceStyle?
    }

    let text: String
    let tone: UserPromptTextTone
    let fontRevision: String
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.layoutDirection) private var layoutDirection

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.isAccessibilityElement = true
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        configure(
            label,
            coordinator: context.coordinator,
            width: label.bounds.width > 0 ? label.bounds.width : nil
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width ?? 10_000
        guard proposedWidth > 0 else { return nil }
        configure(uiView, coordinator: context.coordinator, width: proposedWidth)
        guard let attributedText = uiView.attributedText else { return .zero }
        let measured = attributedText.boundingRect(
            with: CGSize(width: proposedWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let fittedWidth = proposal.width == nil
            ? ceil(measured.width)
            : UserPromptTextLayoutPolicy.fittedWidth(
                measured: ceil(measured.width),
                proposed: proposedWidth
            )
        configure(uiView, coordinator: context.coordinator, width: fittedWidth)
        let size = uiView.sizeThatFits(
            CGSize(width: fittedWidth, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: fittedWidth, height: ceil(size.height))
    }

    private func configure(
        _ label: UILabel,
        coordinator: Coordinator,
        width: CGFloat?
    ) {
        if let width { label.preferredMaxLayoutWidth = width }
        let preferredCategory = label.traitCollection.preferredContentSizeCategory
        let interfaceStyle = label.traitCollection.userInterfaceStyle
        guard coordinator.text != text
                || coordinator.tone != tone
                || coordinator.fontRevision != fontRevision
                || coordinator.sizeCategory != sizeCategory
                || coordinator.layoutDirection != layoutDirection
                || coordinator.preferredContentSizeCategory != preferredCategory
                || coordinator.interfaceStyle != interfaceStyle else { return }
        coordinator.text = text
        coordinator.tone = tone
        coordinator.fontRevision = fontRevision
        coordinator.sizeCategory = sizeCategory
        coordinator.layoutDirection = layoutDirection
        coordinator.preferredContentSizeCategory = preferredCategory
        coordinator.interfaceStyle = interfaceStyle
        let base = TronFontLoader.createUIFont(
            size: TronTypography.sizeBody * UserPromptTextLayoutPolicy.fontScale
        )
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: base,
            compatibleWith: label.traitCollection
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        paragraph.baseWritingDirection = .natural
        paragraph.alignment = UserPromptTextLayoutPolicy.alignment(
            layoutDirection: layoutDirection
        )
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor(tone.color),
                .paragraphStyle: paragraph,
            ]
        )
        label.accessibilityLabel = text
    }

}
