import SwiftUI

// MARK: - Tool Detail Sheet Container

/// Reusable container that provides the shared NavigationStack + toolbar + presentation
/// boilerplate used by all tool detail sheets.
///
/// Usage:
/// ```swift
/// ToolDetailSheetContainer(
///     toolName: "Bash",
///     iconName: "terminal",
///     accent: .tronEmerald,
///     copyContent: command
/// ) {
///     // tool-specific content sections
/// }
/// ```
@available(iOS 26.0, *)
struct ToolDetailSheetContainer<Content: View, LeadingToolbar: View>: View {
    let toolName: String
    let iconName: String
    let accent: Color
    let copyContent: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let leadingToolbar: () -> LeadingToolbar
    @Environment(\.dismiss) private var dismiss

    init(
        toolName: String,
        iconName: String,
        accent: Color,
        copyContent: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder leadingToolbar: @escaping () -> LeadingToolbar
    ) {
        self.toolName = toolName
        self.iconName = iconName
        self.accent = accent
        self.copyContent = copyContent
        self.content = content
        self.leadingToolbar = leadingToolbar
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    leadingToolbar()
                    if let copyContent {
                        Button {
                            UIPasteboard.general.string = copyContent
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(accent.opacity(0.6))
                        }
                        .accessibilityLabel("Copy output")
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(accent)
                        Text(toolName)
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
    }
}

// Convenience init without custom leading toolbar (backward compat for all other tool sheets).
@available(iOS 26.0, *)
extension ToolDetailSheetContainer where LeadingToolbar == EmptyView {
    init(
        toolName: String,
        iconName: String,
        accent: Color,
        copyContent: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.toolName = toolName
        self.iconName = iconName
        self.accent = accent
        self.copyContent = copyContent
        self.content = content
        self.leadingToolbar = { EmptyView() }
    }
}

// MARK: - Sheet Section Padding

/// Single point of control for the horizontal padding applied to each section
/// inside a tool detail sheet. Every section should use `.sheetSection()` instead
/// of raw `.padding(.horizontal)` so the value can be changed in one place.
extension View {
    func sheetSection() -> some View {
        padding(.horizontal)
    }
}
