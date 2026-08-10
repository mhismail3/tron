import SwiftUI

/// Optional state marker rendered immediately before a standard sheet title.
/// The visible dot stays compact while `accessibilityValue` conveys the same
/// state without relying on color alone.
struct SheetTitleIndicator {
    let color: Color
    let accessibilityValue: String
}

/// Shared container for settings pages providing NavigationStack,
/// viewport-constrained scrolling, toolbar, and standard padding.
struct SettingsPageContainer<Leading: View, Content: View>: View {
    let title: String
    let titleIndicator: SheetTitleIndicator?
    let scrollsContent: Bool
    let leadingToolbar: Leading
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        titleIndicator: SheetTitleIndicator? = nil,
        scrollsContent: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) where Leading == EmptyView {
        self.title = title
        self.titleIndicator = titleIndicator
        self.scrollsContent = scrollsContent
        self.leadingToolbar = EmptyView()
        self.content = content
    }

    init(
        title: String,
        titleIndicator: SheetTitleIndicator? = nil,
        scrollsContent: Bool = true,
        @ViewBuilder leadingToolbar: () -> Leading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.titleIndicator = titleIndicator
        self.scrollsContent = scrollsContent
        self.leadingToolbar = leadingToolbar()
        self.content = content
    }

    var body: some View {
        NavigationStack {
            pageContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if Leading.self != EmptyView.self {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            leadingToolbar
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        toolbarTitle
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronEmerald)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var toolbarTitle: some View {
        if let titleIndicator {
            HStack(spacing: 7) {
                Circle()
                    .fill(titleIndicator.color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(TronTypography.button)
                    .foregroundStyle(.tronEmerald)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(titleIndicator.accessibilityValue)
        } else {
            Text(title)
                .font(TronTypography.button)
                .foregroundStyle(.tronEmerald)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if scrollsContent {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        content()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: .top
                    )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            content()
        }
    }
}
