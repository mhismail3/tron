import SwiftUI

enum TronHitTargetShape {
    case rectangle
    case roundedRectangle(cornerRadius: CGFloat)
    case capsule
    case circle
}

private struct TronHitTargetModifier: ViewModifier {
    let shape: TronHitTargetShape
    let minimumSize: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        let sizedContent = content.frame(
            minWidth: minimumSize,
            minHeight: minimumSize
        )

        switch shape {
        case .rectangle:
            sizedContent.contentShape(Rectangle())
        case .roundedRectangle(let cornerRadius):
            sizedContent.contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .capsule:
            sizedContent.contentShape(Capsule())
        case .circle:
            sizedContent.contentShape(Circle())
        }
    }
}

extension View {
    /// Expands the semantic tap region to the visible container used by icon,
    /// pill, and card controls without changing their visual chrome.
    func tronHitTarget(
        _ shape: TronHitTargetShape = .rectangle,
        minimumSize: CGFloat? = nil
    ) -> some View {
        modifier(TronHitTargetModifier(shape: shape, minimumSize: minimumSize))
    }
}

/// Glyph button for navigation and sheet toolbars.
///
/// The label owns a fixed circular content shape so the tappable area covers the
/// visible toolbar control. It uses an explicit circle instead of toolbar
/// button chrome or `glassEffect`, both of which can render wider-than-tall
/// controls in navigation bars.
struct TronToolbarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var color: Color = .tronEmerald
    var font: Font = TronTypography.buttonSM
    var diameter: CGFloat = 44
    var chromeDiameter: CGFloat = 44
    var isBusy = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var fillOpacity: Double {
        colorScheme == .dark ? 0.20 : 0.10
    }

    var body: some View {
        Button {
            guard isEnabled && !isBusy else { return }
            action()
        } label: {
            ZStack {
                Rectangle()
                    .fill(Color.clear)

                Circle()
                    .fill(color.opacity(fillOpacity))
                    .overlay {
                        Circle()
                            .stroke(color.opacity(0.26), lineWidth: 1)
                    }

                if isBusy {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(color)
                } else {
                    Image(systemName: systemImage)
                        .font(font)
                        .foregroundStyle(isEnabled ? color : .tronTextDisabled)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: chromeDiameter, height: chromeDiameter)
            .frame(width: diameter, height: diameter)
            .background(Rectangle().fill(Color.white.opacity(0.001)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .frame(width: diameter, height: diameter)
        .contentShape(Rectangle())
        .containerShape(Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Places app-owned navigation controls from the window safe area instead of
/// inside SwiftUI's navigation toolbar host. The host can stretch custom
/// circular glyph buttons into 52x44pt platters on iOS; this wrapper preserves
/// the visible 44x44pt control and keeps the full frame tappable.
struct TronNavigationTopBarOverlay<Content: View>: View {
    var horizontalPadding: CGFloat = 20
    var topPadding: CGFloat = 48
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            content()
                .frame(height: 44)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, proxy.safeAreaInsets.top + topPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }
}
