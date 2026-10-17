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
    /// False when the content owns its navigation stacks (an interpreted
    /// Swift app's tabs, #909); each stack root then applies
    /// `tronDocumentSheetChrome` itself, so the chrome is never nested.
    let hostsNavigation: Bool
    @State private var selectedDetent: PresentationDetent
    @ViewBuilder let content: () -> Content
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { settingsTheme?.accent ?? .tronBlue }

    init(
        title: String,
        detents: Set<PresentationDetent> = [.large],
        initialDetent: PresentationDetent? = nil,
        leadingAction: TronDocumentSheetAction? = nil,
        hostsNavigation: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.detents = detents
        self.initialDetent = initialDetent
        self.leadingAction = leadingAction
        self.hostsNavigation = hostsNavigation
        _selectedDetent = State(initialValue: initialDetent ?? .large)
        self.content = content
    }

    var body: some View {
        Group {
            if hostsNavigation {
                NavigationStack {
                    content()
                        .tronDocumentSheetChrome(title: title, leadingAction: leadingAction)
                }
            } else {
                content()
            }
        }
        .tint(resolvedAccent)
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

/// The document sheet's navigation chrome: the shared `TronSheetTitle`, an
/// optional leading action and the trailing Done that closes the sheet. Apply
/// it to the root view inside the sheet's NavigationStack; `TronDocumentSheet`
/// does, and content that owns its stacks applies it at each stack root.
private struct TronDocumentSheetChrome: ViewModifier {
    let title: String
    let leadingAction: TronDocumentSheetAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { settingsTheme?.accent ?? .tronBlue }

    func body(content: Content) -> some View {
        content
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
                                .tronToolbarAction(accent: resolvedAccent)
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
                            .tronToolbarAction(accent: resolvedAccent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(resolvedAccent)
    }
}

extension View {
    func tronDocumentSheetChrome(title: String, leadingAction: TronDocumentSheetAction? = nil) -> some View {
        modifier(TronDocumentSheetChrome(title: title, leadingAction: leadingAction))
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
