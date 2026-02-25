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
struct ToolDetailSheetContainer<Content: View>: View {
    let toolName: String
    let iconName: String
    let accent: Color
    let copyContent: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

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
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                if let copyContent {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIPasteboard.general.string = copyContent
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                                .foregroundStyle(accent.opacity(0.6))
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(accent)
                        Text(toolName)
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
    }
}
