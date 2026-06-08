import CoreGraphics
import SwiftUI

/// Pure layout constants for the onboarding wizard shell.
///
/// Keeping these values out of `WizardView` gives tests a stable
/// surface for the invariants users can feel immediately: the wizard
/// canvas uses one fixed size, and the bottom action bar is pinned to
/// the same insets regardless of which step body is sliding.
enum WizardLayout {
    static let width: CGFloat = 480
    static var height: CGFloat {
        WizardStep.allCases.map { $0.preferredHeight }.max() ?? 480
    }
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 24
    static let headerHeight: CGFloat = 28
    static let headerBodySpacing: CGFloat = 18
    static let bottomBarHeight: CGFloat = 54
    static let buttonCornerRadius: CGFloat = 11
    static let progressBarWidth: CGFloat = 82
    static let progressBarHeight: CGFloat = 8
    static let progressBarMinFillWidth: CGFloat = progressBarHeight

    static let transitionAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let progressAnimation = transitionAnimation
}

/// Shared geometry for icon-led cards inside wizard pages.
///
/// The important invariant is optical balance: the space from the card's
/// left edge to the icon column equals the space from that icon column
/// to the text. Without a fixed icon column, wide SF Symbols make the
/// icon look shoved left while the text floats too far away.
enum WizardCardLayout {
    static let cornerRadius: CGFloat = 10
    static let horizontalInset: CGFloat = 18
    static let verticalInset: CGFloat = 10
    static let iconColumnWidth: CGFloat = 32
    static let iconTextSpacing = horizontalInset
}

struct WizardGlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat = WizardCardLayout.cornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape.fill(Color.tronEmerald.opacity(0.055))
                    )
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
            }
            .overlay {
                shape.strokeBorder(Color.tronEmerald.opacity(0.28), lineWidth: 0.8)
            }
            .shadow(color: Color.tronEmerald.opacity(0.08), radius: 10, x: 0, y: 3)
            .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func wizardGlassCard(cornerRadius: CGFloat = WizardCardLayout.cornerRadius) -> some View {
        modifier(WizardGlassCardBackground(cornerRadius: cornerRadius))
    }
}

struct WizardInfoCard<Content: View>: View {
    var verticalPadding = WizardCardLayout.verticalInset
    var horizontalPadding = WizardCardLayout.horizontalInset
    var fillWidth = true
    @ViewBuilder var content: () -> Content

    init(
        verticalPadding: CGFloat = WizardCardLayout.verticalInset,
        horizontalPadding: CGFloat = WizardCardLayout.horizontalInset,
        fillWidth: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.fillWidth = fillWidth
        self.content = content
    }

    var body: some View {
        content()
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            .wizardGlassCard()
    }
}

struct WizardIconTextRow<Icon: View, Content: View, Trailing: View>: View {
    var alignment: VerticalAlignment = .center
    var iconColumnWidth = WizardCardLayout.iconColumnWidth
    var iconTextSpacing = WizardCardLayout.iconTextSpacing
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    init(
        alignment: VerticalAlignment = .center,
        iconColumnWidth: CGFloat = WizardCardLayout.iconColumnWidth,
        iconTextSpacing: CGFloat = WizardCardLayout.iconTextSpacing,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.alignment = alignment
        self.iconColumnWidth = iconColumnWidth
        self.iconTextSpacing = iconTextSpacing
        self.icon = icon
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: alignment, spacing: iconTextSpacing) {
            icon()
                .frame(width: iconColumnWidth, alignment: .center)
            content()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: 0)
            trailing()
                .fixedSize()
        }
    }
}

extension WizardIconTextRow where Trailing == EmptyView {
    init(
        alignment: VerticalAlignment = .center,
        iconColumnWidth: CGFloat = WizardCardLayout.iconColumnWidth,
        iconTextSpacing: CGFloat = WizardCardLayout.iconTextSpacing,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alignment = alignment
        self.iconColumnWidth = iconColumnWidth
        self.iconTextSpacing = iconTextSpacing
        self.icon = icon
        self.content = content
        self.trailing = { EmptyView() }
    }
}
