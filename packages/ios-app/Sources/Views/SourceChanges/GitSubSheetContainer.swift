import SwiftUI

// MARK: - Git Sub-Sheet Container

/// Shared container for all git workflow sub-sheets (Pull Remote / Finalize /
/// Push / Repo Sessions / Conflict Resolver).
///
/// Design goals:
/// - Visual parity across all git workflow sheets (same chrome, spacing, type).
/// - Each sheet carries its own accent color (tint flows to toolbar, title,
///   dismiss affordance).
/// - Partial-height by default so the parent Source Control sheet remains
///   visible in the background.
@available(iOS 26.0, *)
struct GitSubSheetContainer<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
    }
}

// MARK: - Git Hero Card

/// Large icon + title + description block shown at the top of every git
/// sub-sheet. Establishes context for the action that follows.
@available(iOS 26.0, *)
struct GitHeroCard: View {
    let icon: String
    let title: String
    let description: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(width: 46, height: 46)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.opacity(0.14))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(description)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .sectionFill(accent, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Git Action Button

/// Full-width primary action button with inline spinner.
@available(iOS 26.0, *)
struct GitActionButton: View {
    let title: String
    let icon: String
    let accent: Color
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEnabled ? accent : accent.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
    }
}

// MARK: - Git Result Banner

/// Inline result banner (success or failure) shown after an action completes.
@available(iOS 26.0, *)
struct GitResultBanner: View {
    enum Kind { case success, warning, failure }

    let kind: Kind
    let title: String
    var detail: String? = nil

    private var icon: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .success: .tronEmerald
        case .warning: .tronAmber
        case .failure: .tronError
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                if let detail {
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .sectionFill(color, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
