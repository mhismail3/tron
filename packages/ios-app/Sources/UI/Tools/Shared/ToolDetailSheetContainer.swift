import SwiftUI

// MARK: - Tool Detail Sheet Container

/// Reusable container that provides the shared NavigationStack + toolbar + presentation
/// boilerplate used by all tool detail sheets.
///
/// Usage:
/// ```swift
/// ToolDetailSheetContainer(
///     toolName: "filesystem_read",
///     iconName: "terminal",
///     accent: .tronEmerald
/// ) {
///     // tool-specific content sections
/// }
/// ```
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    leadingToolbar()
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(iconColor ?? accent)
                        SheetTitle(title: toolName, color: accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
    }
}

// Convenience init for the common case with no custom leading toolbar.
// Generic init supports sheets that need leading toolbar content.
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
