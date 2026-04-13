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
///     accent: .tronEmerald
/// ) {
///     // tool-specific content sections
/// }
/// ```
@available(iOS 26.0, *)
struct ToolDetailSheetContainer<Content: View, LeadingToolbar: View>: View {
    let toolName: String
    let iconName: String
    let accent: Color
    let iconColor: Color?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let leadingToolbar: () -> LeadingToolbar
    @Environment(\.dismiss) private var dismiss

    init(
        toolName: String,
        iconName: String,
        accent: Color,
        iconColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder leadingToolbar: @escaping () -> LeadingToolbar
    ) {
        self.toolName = toolName
        self.iconName = iconName
        self.accent = accent
        self.iconColor = iconColor
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
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(iconColor ?? accent)
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

// Convenience init for the common case with no custom leading toolbar.
// Only BashToolDetailSheet currently uses the generic init with leadingToolbar:.
@available(iOS 26.0, *)
extension ToolDetailSheetContainer where LeadingToolbar == EmptyView {
    init(
        toolName: String,
        iconName: String,
        accent: Color,
        iconColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.toolName = toolName
        self.iconName = iconName
        self.accent = accent
        self.iconColor = iconColor
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
