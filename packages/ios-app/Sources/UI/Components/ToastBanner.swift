import SwiftUI

// MARK: - Toast banner view

/// A non-blocking toast banner stack rendered at the top safe area. Driven by `ToastCenter`.
///
/// Visual language matches `ConnectionStatusPill` — liquid-glass rounded rect, severity-tinted
/// text/icons, smooth enter/exit transitions. Each toast is individually tappable (dismiss),
/// drag-up-to-dismiss, and supports an optional Retry button.
enum ToastBannerLayout {
    static let horizontalPadding: CGFloat = 12
    static let topPadding: CGFloat = 8
    static let maxWidth: CGFloat = 300
    static let verticalSpacing: CGFloat = 8
    static let pillCornerRadius: CGFloat = 22
    static let contentFontSize: CGFloat = TronTypography.sizeBody3
}

struct ToastBannerStack: View {
    @Bindable var toastCenter: ToastCenter

    var body: some View {
        VStack(spacing: ToastBannerLayout.verticalSpacing) {
            ForEach(toastCenter.toasts) { toast in
                SingleToastBanner(toast: toast, onDismiss: {
                    toastCenter.dismiss(toast.id)
                })
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: ToastBannerLayout.maxWidth)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, ToastBannerLayout.horizontalPadding)
        .padding(.top, ToastBannerLayout.topPadding)
        .animation(.smooth(duration: 0.3), value: toastCenter.toasts)
    }
}

private struct SingleToastBanner: View {
    let toast: ToastCenter.Toast
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let color = colorFor(severity: toast.severity)
        HStack(spacing: 10) {
            iconFor(severity: toast.severity)
                .foregroundStyle(color)

            Text(toast.message)
                .font(TronTypography.sans(size: ToastBannerLayout.contentFontSize, weight: .semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            if let handler = toast.retryHandler {
                Button {
                    onDismiss()
                    Task { await handler() }
                } label: {
                    Text("Retry")
                        .font(TronTypography.sans(size: ToastBannerLayout.contentFontSize, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(
                    Capsule().fill(color.opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(
            .regular.tint(color.opacity(0.25)),
            in: .rect(cornerRadius: ToastBannerLayout.pillCornerRadius)
        )
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Allow drag upward only; ignore pulls down.
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height < -24 {
                        onDismiss()
                    } else {
                        withAnimation(.smooth(duration: 0.2)) { dragOffset = 0 }
                    }
                }
        )
        .onTapGesture {
            onDismiss()
        }
    }

    private func colorFor(severity: ToastCenter.Severity) -> Color {
        switch severity {
        case .success: return .tronSuccess
        case .info: return .tronInfo
        case .warning: return .tronWarning
        case .error: return .tronError
        }
    }

    @ViewBuilder
    private func iconFor(severity: ToastCenter.Severity) -> some View {
        let size = ToastBannerLayout.contentFontSize
        switch severity {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: size, weight: .medium))
        case .info:
            Image(systemName: "info.circle.fill")
                .font(TronTypography.sans(size: size, weight: .medium))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: size, weight: .medium))
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(TronTypography.sans(size: size, weight: .medium))
        }
    }
}

// MARK: - View modifier

struct ToastBannerModifier: ViewModifier {
    @Bindable var toastCenter: ToastCenter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ToastBannerStack(toastCenter: toastCenter)
                    .allowsHitTesting(!toastCenter.toasts.isEmpty)
            }
    }
}

extension View {
    /// Attach the global `ToastCenter`-driven banner stack to this view hierarchy.
    /// Install once at the app root (e.g., `TronMobileApp` content).
    func withToastBanner(center: ToastCenter = .shared) -> some View {
        modifier(ToastBannerModifier(toastCenter: center))
    }
}
