import SwiftUI

struct TronDocumentSheet<Content: View>: View {
    let title: String
    let leadingActions: [TronDocumentSheetAction]
    let hostsNavigation: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var resolvedAccent: Color { TronSheetTint.resolve(nil, theme: settingsTheme) }

    init(
        title: String,
        leadingActions: [TronDocumentSheetAction] = [],
        hostsNavigation: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.leadingActions = leadingActions
        self.hostsNavigation = hostsNavigation
        self.content = content
    }

    var body: some View {
        Group {
            if hostsNavigation {
                NavigationStack {
                    content()
                        .tronDocumentSheetChrome(title: title, leadingActions: leadingActions)
                }
            } else {
                content()
            }
        }
        .tint(resolvedAccent)
        .tronTopBlur(.sheet)
        .tronPresentation()
    }
}

private struct TronDocumentSheetChrome: ViewModifier {
    let title: String
    let leadingActions: [TronDocumentSheetAction]
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
                if !leadingActions.isEmpty {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        ForEach(leadingActions, id: \.accessibilityLabel) { action in
                            Button(action: action.action) {
                                Image(systemName: action.systemImage)
                                    .font(TronTypography.buttonSM)
                                    .tronToolbarAction(accent: resolvedAccent)
                            }
                            .accessibilityLabel(action.accessibilityLabel)
                        }
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
    func tronDocumentSheetChrome(title: String, leadingActions: [TronDocumentSheetAction] = []) -> some View {
        modifier(TronDocumentSheetChrome(title: title, leadingActions: leadingActions))
    }
}

struct TronDocumentSheetAction {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
}
