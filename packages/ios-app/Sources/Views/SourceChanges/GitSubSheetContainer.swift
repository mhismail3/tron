import SwiftUI

// MARK: - Git Sub-Sheet Container

/// Shared container for all git workflow sub-sheets (Pull Remote / Merge
/// Changes / Push Branch / Parallel Sessions / Conflict Resolver).
///
/// Design goals:
/// - Visual parity across all git workflow sheets (same chrome, spacing, type).
/// - Each sheet carries its own accent color (tint flows to toolbar, title,
///   dismiss affordance).
/// - Partial-height by default so the parent Source Control sheet remains
///   visible in the background.
/// - Toolbar layout: `xmark` close on the leading edge + optional primary
///   action on the trailing edge (Pull / Merge / Push / Prune). The trailing
///   action replaces the older full-width bottom button.
@available(iOS 26.0, *)
struct GitSubSheetContainer<Content: View, Leading: View, Trailing: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        accent: Color,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.accent = accent
        self.leading = leading
        self.trailing = trailing
        self.content = content
    }

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
                ToolbarItem(placement: .topBarLeading) {
                    leading()
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    trailing()
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .presentationDragIndicator(.hidden)
        .tint(accent)
    }
}

// Convenience init: default leading is the standard xmark close button. Keeps
// existing call sites unchanged (they only pass `trailing` + `content`) while
// allowing sheets like Parallel Sessions to swap the leading slot for a
// destructive secondary action (e.g. Prune All).
@available(iOS 26.0, *)
extension GitSubSheetContainer where Leading == SheetCloseButton {
    init(
        title: String,
        accent: Color,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            accent: accent,
            leading: { SheetCloseButton(color: accent) },
            trailing: trailing,
            content: content
        )
    }
}

// Convenience init for sheets with no trailing action (e.g. informational
// overlays). Keeps the call site clean: `GitSubSheetContainer(title:accent:)`.
@available(iOS 26.0, *)
extension GitSubSheetContainer where Leading == SheetCloseButton, Trailing == EmptyView {
    init(
        title: String,
        accent: Color,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            accent: accent,
            leading: { SheetCloseButton(color: accent) },
            trailing: { EmptyView() },
            content: content
        )
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
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .sectionFill(accent, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.smooth(duration: 0.25), value: title)
        .animation(.smooth(duration: 0.25), value: description)
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
