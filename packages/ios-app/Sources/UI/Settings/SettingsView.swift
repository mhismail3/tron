import SwiftUI
import TronMobileCore

struct SettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var showsNotifications = false
    @PresentationState private var showsMacTerminal = false
    @PresentationState private var hasRefreshedNotificationBadge = false

    init(onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }) {
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    settingsLink("Appearance", summary: "Dashboard, activity, theme, and fonts",
                                 icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                    settingsLink("Connections", summary: "Paired Macs and authorized devices", icon: "desktopcomputer") {
                        ConnectionsSettingsView()
                    }
                    settingsLink("Model Providers", summary: "Provider accounts and sign-in", icon: "key") {
                        ProvidersSettingsView(sessionID: nil)
                    }
                    settingsLink("MCP Servers", summary: "Tool providers and their sign-ins", icon: "server.rack") {
                        MCPServersSettingsView()
                    }
                    if model.homeStatus.capabilityEnabled, let profileID = model.selectedGatewayProfileID() {
                        HomeTaskSheet(permissionsFor: profileID)
                    }
                }
                .tronSettingsVisualTheme(accent: .tronPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    NotificationInboxToolbarButton(
                        unreadCount: model.notificationInbox.unreadCount,
                        action: { showsNotifications = true }
                    )
                    Button { showsMacTerminal = true } label: {
                        Image(systemName: "apple.terminal")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .tronToolbarAction(accent: .tronPrimary)
                    }
                    .accessibilityLabel("Mac Terminal")
                    .accessibilityIdentifier("settings-mac-terminal")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Settings") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: dynamicTypeSize.isAccessibilitySize ? "xmark" : "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronPrimary)
                            .accessibilityLabel("Done")
                    }
                    .accessibilityIdentifier("settings-done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronManagedSheet(
            isPresented: $showsNotifications,
            identity: "settings.notifications"
        ) {
            NotificationInboxView(onOpenSession: onImported)
        }
        .tronManagedSheet(isPresented: $showsMacTerminal, identity: "settings.Mac Terminal") {
            MacTerminalSheet()
                .tronSettingsVisualTheme(accent: .tronPrimary)
                .tronPresentation()
        }
        .task(id: PresentationActivityTaskID(source: model.settingsFreshness,
                                             presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            try? await model.refreshSettingsSnapshot(for: SettingsTarget.global.gatewayTarget)
        }
        .task(id: presentationActivity.allowsPresentationPublication) {
            guard presentationActivity.allowsPresentationPublication,
                  !hasRefreshedNotificationBadge else { return }
            await model.refreshNotificationInbox()
            guard !Task.isCancelled else { return }
            hasRefreshedNotificationBadge = true
        }
        .tronPresentation()
        .tronSettingsLayout()
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        summary: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronGlassCard {
                TronSettingsRow(icon: icon, title: title, subtitle: summary, subtitleColor: .tronTextSecondary)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityIdentifier("settings-link-\(title)")
    }
}

struct TronProgressiveSheetLink<Label: View, Destination: View>: View {
    let accessibilityLabel: String
    let identity: String
    let destination: () -> Destination
    let label: Label
    let accent: Color?
    let surfaceAccent: Color?
    let onDismiss: (() -> Void)?
    private let fileID: String
    private let line: Int
    @PresentationState private var isPresented: Bool
    @Environment(\.tronSettingsVisualTheme) private var inheritedTheme

    init(
        accessibilityLabel: String,
        identity: String? = nil,
        accent: Color? = nil,
        surfaceAccent: Color? = nil,
        onDismiss: (() -> Void)? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.fileID = fileID
        self.line = line
        self.accessibilityLabel = accessibilityLabel
        self.identity = identity ?? "settings.\(accessibilityLabel)"
        _isPresented = PresentationState(wrappedValue: false, key: "\(self.identity)@\(fileID):\(line)")
        self.accent = accent
        self.surfaceAccent = surfaceAccent
        self.onDismiss = onDismiss
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .tronManagedSheet(
                isPresented: $isPresented,
                identity: identity,
                onDismiss: onDismiss,
                fileID: fileID,
                line: line
            ) {
                NavigationStack {
                    themed(destination()
                        .environment(\.tronSettingsRowAccessory, nil)
                        .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { isPresented = false } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .tronToolbarAction()
                            }
                            .accessibilityLabel("Done")
                        }
                    })
                }
                .tronTopBlur(.sheet)
                .tronPresentation()
                .tronSettingsLayout()
                .tronContentFitSheet()
                .presentationDragIndicator(.hidden)
            }
    }

    @ViewBuilder
    private func themed(_ content: some View) -> some View {
        if let accent {
            content.tronSettingsVisualTheme(accent: accent, surfaceAccent: surfaceAccent)
        } else if let inheritedTheme {
            content.environment(\.tronSettingsVisualTheme, inheritedTheme).tint(inheritedTheme.accent)
        } else {
            content
        }
    }
}
