import SwiftUI

struct TronDocumentSheet<Content: View>: View {
    let title: String
    var detents: Set<PresentationDetent>
    let initialDetent: PresentationDetent?
    let leadingAction: TronDocumentSheetAction?
    let hostsNavigation: Bool
    @State private var selectedDetent: PresentationDetent // view-local: a rebuilt sheet starts at its initial detent
    @ViewBuilder let content: () -> Content
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { TronSheetTint.resolve(nil, theme: settingsTheme) }

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

private struct TronDocumentSheetChrome: ViewModifier {
    let title: String
    let leadingAction: TronDocumentSheetAction?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { TronSheetTint.resolve(nil, theme: settingsTheme) }

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .bottom)
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
                        #if HOSTED_TEST
                        .onAppear { HostedPresentationProbe.record?("document-appear", title) }
                        #endif
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
