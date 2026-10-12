import SwiftUI

struct SettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    #if HOSTED_TEST
    @Environment(\.hostedIntegrationPresentationTrace) private var hostedTrace
    #endif
    @State private var showsNotifications = false
    @State private var hasRefreshedNotificationBadge = false

    init(onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }) {
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    // Settings owns only Mac defaults. Project and Chat editors
                    // retain their own targets; opening Settings never changes scope.
                    SettingsRendererView(
                        target: .object(["kind": .string("mac")]),
                        writeLayer: "mac",
                        embedded: true,
                        sectionSupplement: { AnyView(sectionSupplement($0)) },
                        unresolvedSupplement: AnyView(offlineDestinations)
                    )

                    TronSettingsGroup(
                        "This iPhone",
                        detail: "Stored on this iPhone. Never changes harness behaviour.",
                        accent: .tronEmerald
                    ) {
                        settingsLink("Appearance", summary: "Theme, type scale, and visual preferences",
                                     icon: "circle.lefthalf.filled", accent: .tronEmerald) {
                            AppearanceSettingsView()
                        }
                        settingsDivider(accent: .tronEmerald)
                        settingsLink("Sessions", summary: "Dashboard list and subagent activity",
                                     icon: "slider.horizontal.2.square", accent: .tronEmerald) {
                            AppLocalBehaviorSettingsView()
                        }
                        settingsDivider(accent: .tronBlue)
                        settingsLink("Changes", summary: "Review agent changes and pending approvals", icon: "clock.arrow.circlepath", accent: .tronBlue) {
                            SettingsChangesView(scope: .all)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NotificationInboxToolbarButton(
                        unreadCount: model.notificationInbox.unreadCount,
                        action: { showsNotifications = true }
                    )
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Settings") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: dynamicTypeSize.isAccessibilitySize ? "xmark" : "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                            .accessibilityLabel("Done")
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
        .tronManagedSheet(
            isPresented: $showsNotifications,
            identity: "settings.notifications"
        ) {
            NotificationInboxView(onOpenSession: onImported)
        }
        .task(id: presentationActivity.allowsPresentationPublication) {
            guard presentationActivity.allowsPresentationPublication,
                  !hasRefreshedNotificationBadge else { return }
            // Only the root-owned badge is refreshed here. Destination owners
            // load their own settings data after the sheet transition, keeping
            // unrelated network publications out of the presentation path.
            await model.refreshNotificationInbox()
            guard !Task.isCancelled else { return }
            hasRefreshedNotificationBadge = true
        }
        .tronPresentation()
        .tronSettingsLayout()
        #if HOSTED_TEST
        .onAppear { hostedTrace?.record("settings.root.appear") }
        .onDisappear { hostedTrace?.record("settings.root.disappear") }
        #endif
    }

    private var offlineDestinations: some View {
        VStack(spacing: 18) {
            TronSettingsGroup("Tools") { sectionSupplement("tools") }
            TronSettingsGroup("Permissions") { sectionSupplement("permissions") }
            TronSettingsGroup("Run") { sectionSupplement("run") }
            TronSettingsGroup("Accounts") { sectionSupplement("accounts") }
            TronSettingsGroup("Sources") { sectionSupplement("sources") }
            TronSettingsGroup("Setup") { sectionSupplement("setup") }
        }
    }

    /// Native flows keep their established controls inside the schema's section.
    /// Harness values (including default trust) have just one generic editor.
    @ViewBuilder
    private func sectionSupplement(_ section: String) -> some View {
        switch section {
        case "tools":
            settingsDivider(accent: .tronCyan)
            settingsLink("MCP Servers", summary: "Tool providers and authentication",
                         icon: "server.rack", accent: .tronCyan) {
                MCPServersSettingsView(projectCWD: nil, sessionID: nil)
            }
        case "permissions":
            settingsDivider(accent: .tronPurple)
            settingsLink("Approval floors", summary: "How much of your attention agent changes need",
                         icon: "hand.raised", accent: .tronPurple) {
                PermissionFloorsSettingsView()
            }
        case "run":
            settingsDivider(accent: .tronPurple)
            settingsLink("Hooks", summary: "Loaded event handlers from extensions",
                         icon: "bolt.horizontal.circle", accent: .tronPurple) {
                HooksSettingsView(projectCWD: nil)
            }
        case "accounts":
            settingsLink("Model Providers", summary: "Provider accounts and authentication",
                         icon: "key", accent: .tronPurple) { ProvidersSettingsView(sessionID: nil) }
            settingsDivider(accent: .tronPurple)
            settingsLink("Custom Models", summary: "Saved model definitions and aliases",
                         icon: "slider.horizontal.3", accent: .tronPurple) { CustomModelsSettingsView() }
            settingsDivider(accent: .tronPurple)
            settingsLink("Connected Services", summary: "Accounts and service capabilities",
                         icon: "link", accent: .tronPurple) { IntegrationsSettingsView() }
        case "sources":
            settingsDivider(accent: .tronCyan)
            settingsLink("Extensions", summary: "Installed packages and what they contribute",
                         icon: "shippingbox", accent: .tronCyan) { ExtensionsSettingsView(projectCWD: nil) }
        case "setup":
            settingsDivider(accent: .tronBlue)
            settingsLink("Connections", summary: "Pair Macs, devices, and push readiness",
                         icon: "desktopcomputer", accent: .tronBlue) { ConnectionsSettingsView() }
            settingsDivider(accent: .tronBlue)
            settingsLink("Import", summary: "Restore a session export",
                         icon: "tray.and.arrow.down", accent: .tronBlue) { ImportSettingsView(onImported: onImported) }
            settingsDivider(accent: .tronBlue)
            settingsLink("Logs", summary: "Recent diagnostics from paired Mac gateways",
                         icon: "text.alignleft", accent: .tronBlue) { GatewayLogsSettingsView() }
        default:
            EmptyView()
        }
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        summary: String,
        icon: String,
        accent: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(
            accessibilityLabel: title,
            accent: accent,
            destination: destination
        ) {
            TronSettingsRow(
                icon: icon,
                title: title,
                subtitle: summary,
                subtitleLineLimit: 2,
                accent: accent,
                subtitleColor: .tronTextSecondary
            )
            .contentShape(Rectangle())
        }
    }

    private func settingsDivider(accent: Color) -> some View {
        TronSettingsDivider(accent: accent)
    }
}

enum TronSheetDetentPolicy {
    case fixed(Set<PresentationDetent>)
    case contentFit
}

private struct TronSheetDetentPolicyModifier: ViewModifier {
    let policy: TronSheetDetentPolicy

    func body(content: Content) -> some View {
        switch policy {
        case .fixed(let detents): content.presentationDetents(detents)
        case .contentFit: content.tronContentFitDetents()
        }
    }
}

struct TronProgressiveSheetLink<Label: View, Destination: View>: View {
    let accessibilityLabel: String
    let identity: String
    /// Keep destination construction inside the presented sheet so large
    /// settings payloads are not built while the parent sheet is scrolling.
    let destination: () -> Destination
    let label: Label
    let accent: Color?
    /// Settings destinations open full height; a destination that publishes
    /// `TronSheetFitHeightKey` (the model picker) passes `.contentFit`.
    let detents: TronSheetDetentPolicy
    @State private var isPresented = false
    @Environment(\.tronSettingsVisualTheme) private var inheritedTheme

    init(
        accessibilityLabel: String,
        identity: String? = nil,
        accent: Color? = nil,
        detents: TronSheetDetentPolicy = .fixed([.large]),
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.identity = identity ?? "settings.\(accessibilityLabel)"
        self.accent = accent
        self.detents = detents
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .tronManagedSheet(
                isPresented: $isPresented,
                identity: identity
            ) {
                NavigationStack {
                    destinationContent
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { isPresented = false } label: {
                                    Image(systemName: "checkmark")
                                        .font(TronTypography.buttonSM)
                                        .foregroundStyle(accent ?? inheritedTheme?.accent ?? .tronEmerald)
                                }
                                .accessibilityLabel("Done")
                            }
                        }
                }
                .tronTopBlur(.sheet)
                .tronPresentation()
                .tronSettingsLayout()
                .modifier(TronSheetDetentPolicyModifier(policy: detents))
                .presentationDragIndicator(.hidden)
            }
    }

    @ViewBuilder
    private var destinationContent: some View {
        if let accent {
            destination().tronSettingsVisualTheme(accent: accent)
        } else {
            destination()
        }
    }
}
