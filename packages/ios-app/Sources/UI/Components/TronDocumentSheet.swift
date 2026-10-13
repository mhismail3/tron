import SwiftUI

/// File previews and assembled instructions share one large document surface.
/// Scroll owners supply the soft-edge/top-blur treatment; this owns navigation
/// chrome so native text readers cannot inherit an opaque toolbar or bottom bar.
struct TronDocumentSheet<Content: View>: View {
    let title: String
    /// File previews read at full height; nested instruction readers follow
    /// their parent sheets and start at medium.
    var detents: Set<PresentationDetent>
    let initialDetent: PresentationDetent?
    /// An optional leading toolbar action, such as running a displayed
    /// `.swift` file (#889). Done stays the only trailing control.
    let leadingAction: TronDocumentSheetAction?
    @State private var selectedDetent: PresentationDetent
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { settingsTheme?.accent ?? .tronBlue }

    init(
        title: String,
        detents: Set<PresentationDetent> = [.large],
        initialDetent: PresentationDetent? = nil,
        leadingAction: TronDocumentSheetAction? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.detents = detents
        self.initialDetent = initialDetent
        self.leadingAction = leadingAction
        _selectedDetent = State(initialValue: initialDetent ?? .large)
        self.content = content
    }

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
                    if let leadingAction {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: leadingAction.action) {
                                Image(systemName: leadingAction.systemImage)
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(resolvedAccent)
                            }
                            .accessibilityLabel(leadingAction.accessibilityLabel)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: title, accent: resolvedAccent)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(resolvedAccent)
                        }
                        .accessibilityLabel("Done")
                    }
                }
                .tint(resolvedAccent)
        }
        .tronTopBlur(.sheet)
        .modifier(TronDocumentSheetDetents(
            detents: detents,
            hasInitialSelection: initialDetent != nil,
            selection: $selectedDetent
        ))
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

struct TronDocumentSheetAction {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
}

private struct TronDocumentSheetDetents: ViewModifier {
    let detents: Set<PresentationDetent>
    let hasInitialSelection: Bool
    @Binding var selection: PresentationDetent

    @ViewBuilder
    func body(content: Content) -> some View {
        if hasInitialSelection {
            content.presentationDetents(detents, selection: $selection)
        } else {
            content.presentationDetents(detents)
        }
    }
}
