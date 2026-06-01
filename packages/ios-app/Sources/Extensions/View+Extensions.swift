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
/// Provides a wide, tall floating sheet for detail-heavy iPad flows.
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

/// Compact iPad form sizing for summary sheets that should not consume most
/// of the tablet viewport.
@MainActor
struct CompactFormSizing: PresentationSizing {
    nonisolated func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let screenBounds = MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
                .first ?? .zero
        }
        let fallbackSize = root.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : fallbackSize.width
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : fallbackSize.height

        let width = referenceWidth * 0.58
        let height = min(referenceHeight * 0.58, 620)

        return ProposedViewSize(width: width, height: height)
    }
}

extension PresentationSizing where Self == LargeFormSizing {
    /// A presentation size larger than `.form` but smaller than `.page`
    static var largeForm: LargeFormSizing { LargeFormSizing() }
}

extension PresentationSizing where Self == CompactFormSizing {
    /// A shorter floating iPad form for summary sheets.
    static var compactForm: CompactFormSizing { CompactFormSizing() }
}

enum AdaptivePresentationSizing {
    case largeForm
    case compactForm
}

extension View {
    /// Presentation detents with adaptive sizing for iPad/iPhone:
    /// - iPad: Uses custom `.largeForm` sizing (60% width, 80% height) - smaller than page, larger than form
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

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .presentationDetents(detents, selection: $selectedDetent)

        if isPad {
            switch ipadSizing {
            case .largeForm:
                base
                    .presentationSizing(.largeForm)
                    .presentationBackground(.ultraThinMaterial)
            case .compactForm:
                base
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
