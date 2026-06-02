import SwiftUI

// MARK: - View Extensions

extension View {
    @ViewBuilder
    func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

}

// MARK: - Button Styles

struct TronPrimaryButtonStyle: ButtonStyle {
    let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? .tronBackground : .tronTextDisabled)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isEnabled {
                        LinearGradient.tronEmeraldGradient
                    } else {
                        Color.tronSurfaceElevated
                    }
                }
            )
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.tronFast, value: configuration.isPressed)
    }
}

struct TronSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.tronMint)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .stroke(Color.tronMint, lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.tronFast, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TronPrimaryButtonStyle {
    static var tronPrimary: TronPrimaryButtonStyle { TronPrimaryButtonStyle() }
    static func tronPrimary(isEnabled: Bool) -> TronPrimaryButtonStyle {
        TronPrimaryButtonStyle(isEnabled: isEnabled)
    }
}

extension ButtonStyle where Self == TronSecondaryButtonStyle {
    static var tronSecondary: TronSecondaryButtonStyle { TronSecondaryButtonStyle() }
}

/// Button style with no visual feedback on press - prevents flicker in expandable sections
struct NoFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == NoFeedbackButtonStyle {
    static var noFeedback: NoFeedbackButtonStyle { NoFeedbackButtonStyle() }
}

// MARK: - Adaptive Presentation Detents

/// Custom presentation sizing that's smaller than `.page` but larger than `.form`
/// Preserves the existing non-iPad sheet path used by adaptive presentations.
@MainActor
struct LargeFormSizing: PresentationSizing {
    nonisolated func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let screenBounds = MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
                .first ?? .zero
        }
        let intrinsicSize = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : intrinsicSize.width
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : intrinsicSize.height

        // Use 60% of screen width and 80% of height for a "large form" look
        // This is smaller than .page but larger than .form
        let width = referenceWidth * 0.60
        let height = referenceHeight * 0.80

        return ProposedViewSize(width: width, height: height)
    }
}

private enum AdaptiveSheetMetrics {
    static func balancedLargeFormSize(referenceWidth: CGFloat, referenceHeight: CGFloat) -> CGSize {
        CGSize(
            width: min(referenceWidth * 0.62, 700),
            height: min(referenceHeight * 0.82, 900)
        )
    }

    static func compactFormSize(referenceWidth: CGFloat, referenceHeight: CGFloat) -> CGSize {
        CGSize(
            width: min(referenceWidth * 0.56, 620),
            height: min(referenceHeight * 0.70, 780)
        )
    }
}

/// Balanced iPad form sizing for detail-heavy sheets that should feel like a
/// horizontal floating surface instead of a tall narrow card.
@MainActor
struct BalancedLargeFormSizing: PresentationSizing {
    nonisolated func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let screenBounds = MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
                .first ?? .zero
        }
        let intrinsicSize = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : intrinsicSize.width
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : intrinsicSize.height
        let size = AdaptiveSheetMetrics.balancedLargeFormSize(
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight
        )

        return ProposedViewSize(width: size.width, height: size.height)
    }
}

/// Balanced iPad form sizing for summary sheets that should keep dashboard
/// context visible without becoming a narrow vertical card.
@MainActor
struct CompactFormSizing: PresentationSizing {
    nonisolated func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let screenBounds = MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
                .first ?? .zero
        }
        let intrinsicSize = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : intrinsicSize.width
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : intrinsicSize.height
        let size = AdaptiveSheetMetrics.compactFormSize(
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight
        )

        return ProposedViewSize(width: size.width, height: size.height)
    }
}

extension PresentationSizing where Self == LargeFormSizing {
    /// The existing adaptive sheet size used outside the iPad-specific branch.
    static var largeForm: LargeFormSizing { LargeFormSizing() }
}

extension PresentationSizing where Self == BalancedLargeFormSizing {
    /// A balanced floating iPad form for detail-heavy sheets.
    static var balancedLargeForm: BalancedLargeFormSizing { BalancedLargeFormSizing() }
}

extension PresentationSizing where Self == CompactFormSizing {
    /// A balanced floating iPad form for summary sheets.
    static var compactForm: CompactFormSizing { CompactFormSizing() }
}

enum AdaptivePresentationSizing {
    case largeForm
    case compactForm
}

extension View {
    /// Presentation detents with adaptive sizing for iPad/iPhone:
    /// - iPad: Uses balanced `.balancedLargeForm` or `.compactForm` sizing
    /// - iPad material background keeps floating sheets glassy so dashboard context remains visible
    /// - iPhone keeps the existing detent sizing and background behavior
    ///
    /// On iPad, `presentationDetents` is ignored for floating modals.
    func adaptivePresentationDetents(
        _ detents: Set<PresentationDetent> = [.medium, .large],
        ipadSizing: AdaptivePresentationSizing = .largeForm
    ) -> some View {
        self.modifier(AdaptivePresentationModifier(detents: detents, ipadSizing: ipadSizing))
    }
}

private struct AdaptivePresentationModifier: ViewModifier {
    let detents: Set<PresentationDetent>
    let ipadSizing: AdaptivePresentationSizing
    @State private var selectedDetent: PresentationDetent
    @Environment(\.colorScheme) private var colorScheme

    init(detents: Set<PresentationDetent>, ipadSizing: AdaptivePresentationSizing) {
        self.detents = detents
        self.ipadSizing = ipadSizing
        // Initialize to the smallest detent so the selection binding stays in sync.
        // When only [.large] is provided, this ensures the initial state matches
        // what SwiftUI will present, avoiding a stale .medium default.
        _selectedDetent = State(initialValue: detents.contains(.medium) ? .medium : .large)
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var needsOpaquePhoneBackground: Bool {
        selectedDetent == .large && colorScheme == .light
    }

    private var iPadTargetSize: CGSize {
        let screenBounds = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
            .first ?? .zero
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : 720
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : 960

        switch ipadSizing {
        case .largeForm:
            return AdaptiveSheetMetrics.balancedLargeFormSize(
                referenceWidth: referenceWidth,
                referenceHeight: referenceHeight
            )
        case .compactForm:
            return AdaptiveSheetMetrics.compactFormSize(
                referenceWidth: referenceWidth,
                referenceHeight: referenceHeight
            )
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .presentationDetents(detents, selection: $selectedDetent)

        if isPad {
            let targetSize = iPadTargetSize
            let ipadBase = base
                .presentationContentInteraction(.scrolls)
                .frame(width: targetSize.width, height: targetSize.height)
            switch ipadSizing {
            case .largeForm:
                ipadBase
                    .presentationSizing(.balancedLargeForm)
                    .presentationBackground(.ultraThinMaterial)
            case .compactForm:
                ipadBase
                    .presentationSizing(.compactForm)
                    .presentationBackground(.ultraThinMaterial)
            }
        } else {
            base
                .presentationSizing(.largeForm)
                .presentationBackground(needsOpaquePhoneBackground ? Color.tronBackground : .clear)
        }
    }
}
