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
/// Provides approximately 85% of the available space on iPad
@MainActor
struct LargeFormSizing: PresentationSizing {
    nonisolated func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let screenBounds = MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
                .first ?? .zero
        }
        let fallbackSize = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : fallbackSize.width
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : fallbackSize.height

        // Use 60% of screen width and 80% of height for a "large form" look
        // This is smaller than .page but larger than .form
        let width = referenceWidth * 0.60
        let height = referenceHeight * 0.80

        return ProposedViewSize(width: width, height: height)
    }
}

extension PresentationSizing where Self == LargeFormSizing {
    /// A presentation size larger than `.form` but smaller than `.page`
    static var largeForm: LargeFormSizing { LargeFormSizing() }
}

extension View {
    /// Presentation detents with adaptive sizing for iPad/iPhone:
    /// - iPad: Uses custom `.largeForm` sizing (60% width, 80% height) - smaller than page, larger than form
    /// - iPhone: Uses `.presentationDetents` to allow medium/large sizing
    /// - iOS 26+: Partial-height detents automatically get Liquid Glass appearance
    /// - Large detent in light mode gets cream background to match dashboard
    ///
    /// On iPad, `presentationDetents` is ignored for floating modals.
    func adaptivePresentationDetents(_ detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        self.modifier(AdaptivePresentationModifier(detents: detents))
    }
}

private struct AdaptivePresentationModifier: ViewModifier {
    let detents: Set<PresentationDetent>
    @State private var selectedDetent: PresentationDetent

    init(detents: Set<PresentationDetent>) {
        self.detents = detents
        // Initialize to the smallest detent so the selection binding stays in sync.
        // When only [.large] is provided, this ensures the initial state matches
        // what SwiftUI will present, avoiding a stale .medium default.
        _selectedDetent = State(initialValue: detents.contains(.medium) ? .medium : .large)
    }
    @Environment(\.colorScheme) private var colorScheme

    private var needsOpaqueBackground: Bool {
        selectedDetent == .large && colorScheme == .light
    }

    func body(content: Content) -> some View {
        content
            .presentationDetents(detents, selection: $selectedDetent)
            .presentationSizing(.largeForm)
            .presentationBackground(needsOpaqueBackground ? Color.tronBackground : .clear)
    }
}
