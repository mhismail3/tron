import SwiftUI

// MARK: - Sheet Title

/// Standard principal toolbar title used across all sheets.
/// Renders mono semibold sizeTitle text in the given accent color.
@available(iOS 26.0, *)
struct SheetTitle: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
            .foregroundStyle(color)
    }
}

// MARK: - Sheet Dismiss Button

/// Standard checkmark dismiss button for sheet trailing toolbar.
@available(iOS 26.0, *)
struct SheetDismissButton: View {
    let color: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "checkmark")
                .font(TronTypography.buttonSM)
                .foregroundStyle(color)
        }
        .accessibilityLabel("Close")
    }
}

// MARK: - Error Alert

/// Standard error alert driven by an optional error message string.
/// Replaces the repeated `Binding(get: { msg != nil }, set: { ... })` + OK button pattern.
struct TronErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
    }
}

extension View {
    func tronErrorAlert(message: Binding<String?>) -> some View {
        modifier(TronErrorAlert(message: message))
    }
}

// MARK: - Loading Toolbar Button

/// Toolbar button with a loading spinner that replaces the icon while an async action is in progress.
@available(iOS 26.0, *)
struct LoadingToolbarButton: View {
    let label: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(color)
                } else {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                }
                Text(label)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(isEnabled ? color : .tronTextMuted)
        }
        .disabled(!isEnabled || isLoading)
    }
}
