import SwiftUI

/// Shared container for settings pages providing NavigationStack,
/// viewport-constrained scrolling, toolbar, and standard padding.
struct SettingsPageContainer<Leading: View, Content: View>: View {
    let title: String
    let scrollsContent: Bool
    let leadingToolbar: Leading
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        scrollsContent: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) where Leading == EmptyView {
        self.title = title
        self.scrollsContent = scrollsContent
        self.leadingToolbar = EmptyView()
        self.content = content
    }

    init(
        title: String,
        scrollsContent: Bool = true,
        @ViewBuilder leadingToolbar: () -> Leading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
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
                        ToolbarItem(placement: .topBarLeading) {
                            leadingToolbar
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(TronTypography.button)
                            .foregroundStyle(.tronEmerald)
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
