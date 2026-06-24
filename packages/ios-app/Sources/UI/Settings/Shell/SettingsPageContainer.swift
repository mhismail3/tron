import SwiftUI

/// Shared container for settings pages providing NavigationStack,
/// viewport-constrained scrolling, toolbar, and standard padding.
struct SettingsPageContainer<Leading: View, Content: View>: View {
    let title: String
    let leadingToolbar: Leading
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) where Leading == EmptyView {
        self.title = title
        self.leadingToolbar = EmptyView()
        self.content = content
    }

    init(
        title: String,
        @ViewBuilder leadingToolbar: () -> Leading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.leadingToolbar = leadingToolbar()
        self.content = content
    }

    var body: some View {
        NavigationStack {
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
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
}
