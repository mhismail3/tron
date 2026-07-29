import SwiftUI

/// Standard sheet chrome for resolved delivery and wait cards.
///
/// The parent supplies the same card views used for active session state so
/// history cannot drift into a second presentation vocabulary.
struct SessionContextDeliveryHistorySheet<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Recent Delivery History", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }
}
