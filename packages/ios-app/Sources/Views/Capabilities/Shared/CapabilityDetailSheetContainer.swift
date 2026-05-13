import SwiftUI

// MARK: - Tool Detail Sheet Container

/// Reusable container that provides the shared NavigationStack + toolbar + presentation
/// boilerplate used by all tool detail sheets.
///
/// Usage:
/// ```swift
/// CapabilityDetailSheetContainer(
///     modelToolName: "Bash",
///     iconName: "terminal",
///     accent: .tronEmerald
/// ) {
///     // tool-specific content sections
/// }
/// ```
@available(iOS 26.0, *)
struct CapabilityDetailSheetContainer<Content: View, LeadingToolbar: View>: View {
    let modelToolName: String
    let iconName: String
    let accent: Color
    let iconColor: Color?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let leadingToolbar: () -> LeadingToolbar
    @Environment(\.dismiss) private var dismiss

    init(
        modelToolName: String,
        iconName: String,
        accent: Color,
        iconColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder leadingToolbar: @escaping () -> LeadingToolbar
    ) {
        self.modelToolName = modelToolName
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
                        SheetTitle(title: modelToolName, color: accent)
                    }
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

// Convenience init for the common case with no custom leading toolbar.
// Generic init supports sheets that need leading toolbar content.
@available(iOS 26.0, *)
extension CapabilityDetailSheetContainer where LeadingToolbar == EmptyView {
    init(
        modelToolName: String,
        iconName: String,
        accent: Color,
        iconColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.modelToolName = modelToolName
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
