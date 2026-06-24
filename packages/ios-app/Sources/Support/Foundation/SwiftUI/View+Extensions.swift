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
    static func balancedLargeFormSize(
        referenceWidth: CGFloat,
        referenceHeight: CGFloat,
        intrinsicSize: CGSize? = nil
    ) -> CGSize {
        let maxHeight = min(referenceHeight * 0.88, 900)
        return CGSize(
            width: min(referenceWidth * 0.46, 540),
            height: clampedHeight(intrinsicSize?.height, minHeight: min(540, maxHeight), maxHeight: maxHeight)
        )
    }

    static func compactFormSize(
        referenceWidth: CGFloat,
        referenceHeight: CGFloat,
        intrinsicSize: CGSize? = nil
    ) -> CGSize {
        let maxHeight = min(referenceHeight * 0.78, 760)
        return CGSize(
            width: min(referenceWidth * 0.40, 470),
            height: clampedHeight(intrinsicSize?.height, minHeight: min(420, maxHeight), maxHeight: maxHeight)
        )
    }

    private static func clampedHeight(_ intrinsicHeight: CGFloat?, minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard let intrinsicHeight, intrinsicHeight > 0 else { return maxHeight }
        return min(max(intrinsicHeight, minHeight), maxHeight)
    }
}

/// Balanced iPad form sizing for detail-heavy sheets that should feel like a
/// floating form instead of an edge-to-edge sheet.
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
        let size = AdaptivePresentationSizing.largeForm.targetSize(
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight,
            intrinsicSize: intrinsicSize
        )

        return ProposedViewSize(width: size.width, height: size.height)
    }
}

/// Balanced iPad form sizing for summary sheets that should keep session list
/// context visible without becoming an oversized panel.
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
        let size = AdaptivePresentationSizing.compactForm.targetSize(
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight,
            intrinsicSize: intrinsicSize
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

    func targetSize(referenceWidth: CGFloat, referenceHeight: CGFloat, intrinsicSize: CGSize? = nil) -> CGSize {
        switch self {
        case .largeForm:
            return AdaptiveSheetMetrics.balancedLargeFormSize(
                referenceWidth: referenceWidth,
                referenceHeight: referenceHeight,
                intrinsicSize: intrinsicSize
            )
        case .compactForm:
            return AdaptiveSheetMetrics.compactFormSize(
                referenceWidth: referenceWidth,
                referenceHeight: referenceHeight,
                intrinsicSize: intrinsicSize
            )
        }
    }
}

enum AdaptivePhonePresentationSizing {
    case largeForm
    case unchanged
}

enum AdaptivePhonePresentationBackground {
    case automaticLargeDetent
    case clear
    case unchanged
}

enum AdaptiveIPadPresentationBackground {
    case material
    case clear
    case unchanged
}

extension View {
    /// Clear presentation background for glass popovers. Detented sheets should
    /// use `adaptivePresentationDetents` so iPad sizing/background stays centralized.
    func glassPopoverPresentationBackground() -> some View {
        presentationBackground(.clear)
    }

    /// Keep popover actions as popovers on compact-width presentations instead
    /// of allowing them to use sheet styling.
    func popoverCompactAdaptation() -> some View {
        presentationCompactAdaptation(.popover)
    }

    /// Canonical presentation for short custom-height sheets.
    func compactHeightSheetPresentation(
        height: CGFloat,
        dragIndicator: Visibility = .hidden
    ) -> some View {
        adaptivePresentationDetents(
            [.height(height)],
            ipadSizing: .compactForm,
            phoneSizing: .unchanged,
            phoneBackground: .unchanged,
            dragIndicator: dragIndicator
        )
    }

    /// Canonical presentation for immersive camera sheets whose visual surface
    /// must fill the entire modal, including sheet safe-area reservations.
    func immersiveCameraSheetPresentation<Background: View>(
        @ViewBuilder background: @escaping () -> Background
    ) -> some View {
        adaptivePresentationDetents(
            [.medium],
            ipadSizing: .compactForm,
            ipadFillsHeight: true,
            ipadBackground: .clear,
            phoneSizing: .unchanged,
            phoneBackground: .clear
        )
        .presentationBackground(alignment: .center) {
            background()
                .ignoresSafeArea(.container, edges: .all)
        }
    }

    /// Presentation detents with adaptive sizing for iPad/iPhone:
    /// - iPad: Uses balanced `.balancedLargeForm` or `.compactForm` sizing
    /// - iPad material background keeps floating sheets glassy so session list context remains visible
    /// - Drag indicators are hidden consistently for Tron app sheets
    /// - iPhone keeps the existing detent sizing and background behavior
    ///
    /// On iPad, `presentationDetents` is ignored for floating modals.
    func adaptivePresentationDetents(
        _ detents: Set<PresentationDetent> = [.medium, .large],
        selection: Binding<PresentationDetent>? = nil,
        ipadSizing: AdaptivePresentationSizing = .largeForm,
        ipadFillsHeight: Bool = false,
        ipadBackground: AdaptiveIPadPresentationBackground = .material,
        phoneSizing: AdaptivePhonePresentationSizing = .largeForm,
        phoneBackground: AdaptivePhonePresentationBackground = .automaticLargeDetent,
        dragIndicator: Visibility = .hidden
    ) -> some View {
        self.modifier(AdaptivePresentationModifier(
            detents: detents,
            selection: selection,
            ipadSizing: ipadSizing,
            ipadFillsHeight: ipadFillsHeight,
            ipadBackground: ipadBackground,
            phoneSizing: phoneSizing,
            phoneBackground: phoneBackground,
            dragIndicator: dragIndicator
        ))
    }
}

private struct AdaptivePresentationModifier: ViewModifier {
    let detents: Set<PresentationDetent>
    let selection: Binding<PresentationDetent>?
    let ipadSizing: AdaptivePresentationSizing
    let ipadFillsHeight: Bool
    let ipadBackground: AdaptiveIPadPresentationBackground
    let phoneSizing: AdaptivePhonePresentationSizing
    let phoneBackground: AdaptivePhonePresentationBackground
    let dragIndicator: Visibility
    @State private var selectedDetent: PresentationDetent
    @Environment(\.colorScheme) private var colorScheme

    init(
        detents: Set<PresentationDetent>,
        selection: Binding<PresentationDetent>?,
        ipadSizing: AdaptivePresentationSizing,
        ipadFillsHeight: Bool,
        ipadBackground: AdaptiveIPadPresentationBackground,
        phoneSizing: AdaptivePhonePresentationSizing,
        phoneBackground: AdaptivePhonePresentationBackground,
        dragIndicator: Visibility
    ) {
        self.detents = detents
        self.selection = selection
        self.ipadSizing = ipadSizing
        self.ipadFillsHeight = ipadFillsHeight
        self.ipadBackground = ipadBackground
        self.phoneSizing = phoneSizing
        self.phoneBackground = phoneBackground
        self.dragIndicator = dragIndicator
        // Initialize to the smallest detent so the selection binding stays in sync.
        // When only [.large] is provided, this ensures the initial state matches
        // what SwiftUI will present, avoiding a stale .medium default.
        _selectedDetent = State(initialValue: detents.contains(.medium) ? .medium : .large)
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var needsOpaquePhoneBackground: Bool {
        phoneSelectedDetent == .large && colorScheme == .light
    }

    private var phoneSelectedDetent: PresentationDetent {
        selection?.wrappedValue ?? selectedDetent
    }

    private var phoneSelection: Binding<PresentationDetent> {
        selection ?? $selectedDetent
    }

    private var iPadTargetSize: CGSize {
        let screenBounds = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
            .first ?? .zero
        let referenceWidth = screenBounds.width > 0 ? screenBounds.width : 720
        let referenceHeight = screenBounds.height > 0 ? screenBounds.height : 960

        return ipadSizing.targetSize(referenceWidth: referenceWidth, referenceHeight: referenceHeight)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPad {
            let targetSize = iPadTargetSize
            let ipadBase = ipadContent(content: content, targetSize: targetSize)
            switch ipadSizing {
            case .largeForm:
                ipadBackgroundBody(content: ipadBase)
                    .presentationSizing(.balancedLargeForm)
                    .presentationDragIndicator(dragIndicator)
            case .compactForm:
                ipadBackgroundBody(content: ipadBase)
                    .presentationSizing(.compactForm)
                    .presentationDragIndicator(dragIndicator)
            }
        } else {
            phoneBody(content: content)
        }
    }

    @ViewBuilder
    private func ipadBackgroundBody<SheetContent: View>(content: SheetContent) -> some View {
        switch ipadBackground {
        case .material:
            content.presentationBackground(.ultraThinMaterial)
        case .clear:
            content.presentationBackground(.clear)
        case .unchanged:
            content
        }
    }

    @ViewBuilder
    private func ipadContent<SheetContent: View>(content: SheetContent, targetSize: CGSize) -> some View {
        let widthConstrained = content
            .presentationContentInteraction(.scrolls)
            .frame(width: targetSize.width)

        if ipadFillsHeight {
            widthConstrained
                .frame(height: targetSize.height)
        } else {
            widthConstrained
                .frame(maxHeight: targetSize.height)
        }
    }

    @ViewBuilder
    private func phoneBody(content: Content) -> some View {
        let detented = content
            .presentationDetents(detents, selection: phoneSelection)
            .presentationDragIndicator(dragIndicator)
        switch phoneSizing {
        case .largeForm:
            phoneBackgroundBody(content: detented.presentationSizing(.largeForm))
        case .unchanged:
            phoneBackgroundBody(content: detented)
        }
    }

    @ViewBuilder
    private func phoneBackgroundBody<PhoneContent: View>(content: PhoneContent) -> some View {
        switch phoneBackground {
        case .automaticLargeDetent:
            content.presentationBackground(needsOpaquePhoneBackground ? Color.tronBackground : .clear)
        case .clear:
            content.presentationBackground(.clear)
        case .unchanged:
            content
        }
    }
}
