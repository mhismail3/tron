import SwiftUI
import UIKit

@MainActor
extension ChatNotificationTone {
    /// Small compact-pill text uses contrast-safe foregrounds independently of
    /// the brighter semantic surface tint.
    var primaryColor: Color {
        switch self {
        case .accent: .tronAccentText
        case .information: Color(lightHex: "#0369A1", darkHex: "#38BDF8")
        case .warning: Color(lightHex: "#92400E", darkHex: "#FBBF24")
        case .error: .tronError
        case .neutral: Color(lightHex: "#475569", darkHex: "#CBD5E1")
        }
    }

    var secondaryColor: Color {
        switch self {
        case .accent: Color(lightHex: "#047857", darkHex: "#A7F3D0")
        case .information: Color(lightHex: "#075985", darkHex: "#7DD3FC")
        case .warning: Color(lightHex: "#78350F", darkHex: "#FDE68A")
        case .error: Color(lightHex: "#991B1B", darkHex: "#FCA5A5")
        case .neutral: Color(lightHex: "#334155", darkHex: "#E2E8F0")
        }
    }

    var surfaceColor: Color {
        switch self {
        case .accent: .tronEmerald
        case .information: .tronInfo
        case .warning: .tronAmber
        case .error: .tronError
        case .neutral: .tronSlate
        }
    }
}

enum ChatCompactPillLayoutPolicy {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let itemSpacing: CGFloat = 6
    static let standardIconSize: CGFloat = 12
    static let toolIconSize: CGFloat = 12
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
    @ViewBuilder let content: Content

    init(
        tone: ChatNotificationTone,
        material: ChatNotificationMaterial,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.tone = tone
        self.material = material
        self.interactive = interactive
        self.content = content()
    }

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: ChatCompactPillLayoutPolicy.cornerRadius(for: tone),
            style: .continuous
        )
        switch material {
        case .glass:
            content
                .padding(.horizontal, ChatCompactPillLayoutPolicy.horizontalPadding)
                .padding(.vertical, ChatCompactPillLayoutPolicy.verticalPadding)
                .contentShape(shape)
                .glassEffect(
                    .regular.tint(tone.surfaceColor.opacity(0.18)).interactive(interactive),
                    in: shape
                )
        case .flat:
            content
                .padding(.horizontal, ChatCompactPillLayoutPolicy.horizontalPadding)
                .padding(.vertical, ChatCompactPillLayoutPolicy.verticalPadding)
                .contentShape(shape)
                .background(tone.surfaceColor.opacity(0.10), in: shape)
                .overlay(shape.stroke(tone.surfaceColor.opacity(0.30), lineWidth: 0.5))
        }
    }
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
            ? .error : run.isRunning ? .warning : .accent
        let single = run.displayCount == 1 ? run.tools.first : nil
        return Self(
            id: run.id,
            title: run.title,
            detail: single?.subtitle.lowercased() ?? run.status,
            icon: run.failureCount > 0
                ? "exclamationmark.triangle.fill"
                : single.map { ToolDetailPresentation.icon(for: $0.title) }
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

struct ChatCompactPillLabel<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String?
    let tone: ChatNotificationTone
    let showsProgress: Bool
    let iconSize: CGFloat
    let titleWeight: Font.Weight
    let detailStyle: ChatCompactPillDetailStyle
    @ViewBuilder let trailing: Trailing

    init(
        icon: String,
        title: String,
        detail: String? = nil,
        tone: ChatNotificationTone,
        showsProgress: Bool = false,
        iconSize: CGFloat = ChatCompactPillLayoutPolicy.standardIconSize,
        titleWeight: Font.Weight = .bold,
        detailStyle: ChatCompactPillDetailStyle = .status,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.tone = tone
        self.showsProgress = showsProgress
        self.iconSize = iconSize
        self.titleWeight = titleWeight
        self.detailStyle = detailStyle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
            ZStack {
                if showsProgress {
                    ProgressView().controlSize(.small).tint(tone.primaryColor)
                } else {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: iconSize, weight: .semibold))
                        .foregroundStyle(tone.primaryColor)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: titleWeight))
                .foregroundStyle(tone.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(detailStyle == .summary
                        ? TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium)
                        : TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(detailStyle == .summary
                        ? Color.tronTextSecondary : tone.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
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
        titleWeight: Font.Weight = .bold,
        detailStyle: ChatCompactPillDetailStyle = .status
    ) {
        self.init(
            icon: icon,
            title: title,
            detail: detail,
            tone: tone,
            showsProgress: showsProgress,
            iconSize: iconSize,
            titleWeight: titleWeight,
            detailStyle: detailStyle,
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

/// UIKit/TextKit retains deterministic wrapping and Dynamic Type while SwiftUI
/// owns the narrower right-anchored prompt block.
struct UserPromptText: View {
    let text: String
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        // Reading the selected family and axes makes Observation invalidate this
        // wrapper when the app's live typography settings change.
        let family = fontSettings.selectedFamily
        let weight = fontSettings.axisValue(for: family, axis: .weight)
        let casual = fontSettings.axisValue(for: family, axis: .casual)
        UserPromptLabel(
            text: text,
            fontRevision: "\(family.rawValue):\(weight):\(casual)"
        )
        .accessibilityLabel(text)
    }
}

private struct UserPromptLabel: UIViewRepresentable {
    let text: String
    let fontRevision: String
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.layoutDirection) private var layoutDirection

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
        configure(label, width: label.bounds.width > 0 ? label.bounds.width : nil)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        let proposedWidth = proposal.width ?? 10_000
        guard proposedWidth > 0 else { return nil }
        configure(uiView, width: proposedWidth)
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
        configure(uiView, width: fittedWidth)
        let size = uiView.sizeThatFits(
            CGSize(width: fittedWidth, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: fittedWidth, height: ceil(size.height))
    }

    private func configure(_ label: UILabel, width: CGFloat?) {
        _ = fontRevision
        _ = sizeCategory
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
                .foregroundColor: UIColor(Color.userMessageText),
                .paragraphStyle: paragraph,
            ]
        )
        label.accessibilityLabel = text
        if let width { label.preferredMaxLayoutWidth = width }
    }

}
