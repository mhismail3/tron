import SwiftUI

/// File previews and assembled instructions share one large document surface.
/// Scroll owners supply the soft-edge/top-blur treatment; this owns navigation
/// chrome so native text readers cannot inherit an opaque toolbar or bottom bar.
struct TronDocumentSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content()
                // UIKit text readers otherwise stop above the home-indicator
                // safe area, leaving a hard empty strip unlike SwiftUI documents.
                .ignoresSafeArea(.container, edges: .bottom)
                // Let the native sheet material show through, matching standard
                // sheets in both appearances instead of painting an opaque page.
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
                .toolbar(.hidden, for: .bottomBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: title, accent: .tronBlue)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronBlue)
                        }
                        .accessibilityLabel("Done")
                    }
                }
                .tint(Color.tronBlue)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}
