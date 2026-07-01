import SwiftUI

// MARK: - Compact Height Sheet Layout

/// Shared metrics for short custom-height sheets that present a compact grid of
/// direct actions.
enum CompactActionSheetLayout {
    static let columnCount = 3
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let tileMinHeight: CGFloat = 78
    static let toolbarHeight: CGFloat = 80
    static let bottomPadding: CGFloat = 18

    static func columns(forItemCount itemCount: Int) -> [GridItem] {
        let visibleColumnCount = min(max(itemCount, 1), columnCount)
        return Array(
            repeating: GridItem(.flexible(), spacing: columnSpacing),
            count: visibleColumnCount
        )
    }

    static func rowCount(forItemCount itemCount: Int) -> Int {
        let normalizedCount = max(itemCount, 1)
        return max(1, (normalizedCount + columnCount - 1) / columnCount)
    }

    static func sheetHeight(forItemCount itemCount: Int) -> CGFloat {
        let rows = CGFloat(rowCount(forItemCount: itemCount))
        let interRowSpacing = max(0, rows - 1) * rowSpacing
        return toolbarHeight
            + (verticalPadding * 2)
            + (rows * tileMinHeight)
            + interRowSpacing
            + bottomPadding
    }
}

// MARK: - Compact Action Sheet Button

/// Settings-grid style action tile for short custom-height sheets.
struct CompactActionSheetButton: View {
    let title: String
    let systemImage: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(height: 24)
                    .accessibilityHidden(true)

                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: CompactActionSheetLayout.tileMinHeight)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .sectionFill(accent, interactive: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(title)
    }
}

// MARK: - Sheet Title

/// Standard principal toolbar title used across all sheets.
/// Renders mono semibold sizeTitle text in the given accent color.
struct SheetTitle: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
            .foregroundStyle(color)
    }
}

// MARK: - Sheet Dismiss Button

/// Standard checkmark dismiss button for sheet trailing toolbar.
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

// MARK: - Sheet Close Button

/// Standard `xmark` dismiss button, used in the top-leading toolbar slot of
/// sheets whose top-trailing slot is reserved for a primary action.
struct SheetCloseButton: View {
    let color: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(TronTypography.buttonSM)
                .foregroundStyle(color)
        }
        .accessibilityLabel("Close")
    }
}

// MARK: - Sheet Primary Action Button

/// Glyph-only toolbar button used as the primary action of a sheet
/// (top-trailing slot, replacing the checkmark dismiss). Shows a spinner
/// while `isBusy`, and fades to muted when disabled.
struct SheetPrimaryActionButton: View {
    let icon: String
    let accent: Color
    var isBusy: Bool = false
    var isEnabled: Bool = true
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(accent)
            } else {
                Image(systemName: icon)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(isEnabled ? accent : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(accessibilityLabel)
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
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(isEnabled ? color : .tronTextMuted)
        }
        .disabled(!isEnabled || isLoading)
    }
}
