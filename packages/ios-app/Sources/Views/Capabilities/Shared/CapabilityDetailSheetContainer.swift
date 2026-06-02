import SwiftUI

// MARK: - Capability Detail Sheet Container

/// Reusable container that provides the shared NavigationStack + toolbar + presentation
/// boilerplate used by all capability detail sheets.
///
/// Usage:
/// ```swift
/// CapabilityDetailSheetContainer(
///     modelPrimitiveName: "execute",
///     iconName: "terminal",
///     accent: .tronEmerald
/// ) {
///     // capability-specific content sections
/// }
/// ```
@available(iOS 26.0, *)
struct CapabilityDetailSheetContainer<Content: View, LeadingToolbar: View>: View {
    let modelPrimitiveName: String
    let iconName: String
    let accent: Color
    let iconColor: Color?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let leadingToolbar: () -> LeadingToolbar
    @Environment(\.dismiss) private var dismiss

    init(
        modelPrimitiveName: String,
        iconName: String,
        accent: Color,
        iconColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder leadingToolbar: @escaping () -> LeadingToolbar
    ) {
        self.modelPrimitiveName = modelPrimitiveName
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
                        SheetTitle(title: modelPrimitiveName, color: accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .presentationDragIndicator(.hidden)
        .tint(accent)
    }
}

// Convenience init for the common case with no custom leading toolbar.
// Generic init supports sheets that need leading toolbar content.
@available(iOS 26.0, *)
extension CapabilityDetailSheetContainer where LeadingToolbar == EmptyView {
    init(
        modelPrimitiveName: String,
        iconName: String,
        accent: Color,
        iconColor: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.modelPrimitiveName = modelPrimitiveName
        self.iconName = iconName
        self.accent = accent
        self.iconColor = iconColor
        self.content = content
        self.leadingToolbar = { EmptyView() }
    }
}

// MARK: - Sheet Section Padding

/// Single point of control for the horizontal padding applied to each section
/// inside a capability detail sheet. Every section should use `.sheetSection()` instead
/// of raw `.padding(.horizontal)` so the value can be changed in one place.
extension View {
    func sheetSection() -> some View {
        padding(.horizontal)
    }
}
