import SwiftUI

struct SettingsView: View {
    enum Scope { case dashboard, project }

    let scope: Scope
    let projectSessionID: String?
    let projectCWD: String?
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var showsNotifications = false
    @State private var hasRefreshedNotificationBadge = false

    init(
        scope: Scope = .dashboard,
        projectSessionID: String? = nil,
        projectCWD: String? = nil,
        onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }
    ) {
        self.scope = scope
        self.projectSessionID = scope == .project ? projectSessionID : nil
        self.projectCWD = scope == .project ? projectCWD : nil
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    // Match the Connections surface: each logical group gets
                    // its own glass container and header instead of one long,
                    // undifferentiated card.
                    TronSettingsGroup("App & Connections", accent: .tronEmerald) {
                        settingsLink(
                            "Appearance",
                            summary: "Theme, type scale, and visual preferences",
                            icon: "circle.lefthalf.filled",
                            accent: .tronEmerald
                        ) { AppearanceSettingsView() }
                        settingsDivider(accent: .tronEmerald)
                        settingsLink(
                            "Connections",
                            summary: "Pair and manage Mac gateways",
                            icon: "desktopcomputer",
                            accent: .tronEmerald
                        ) { ConnectionsSettingsView() }
                    }

                    TronSettingsGroup("Agent", accent: .tronPurple) {
                        settingsLink(
                            "Providers",
                            summary: "Authentication and provider credentials",
                            icon: "key",
                            accent: .tronPurple
                        ) {
                            ProvidersSettingsView(sessionID: projectSessionID)
                        }
                        settingsDivider(accent: .tronPurple)
                        settingsLink(
                            "Models and Defaults",
                            summary: "Default model, thinking, and selection policy",
                            icon: "cpu",
                            accent: .tronPurple
                        ) {
                            AgentDefaultsSettingsView(
                                allowsProjectScope: scope == .project,
                                providerTarget: projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global,
                                projectCWD: projectCWD
                            )
                        }
                        settingsDivider(accent: .tronPurple)
                        settingsLink(
                            "Runtime Behavior",
                            summary: "Prompt queue, retries, and compaction behavior",
                            icon: "gearshape.2",
                            accent: .tronPurple
                        ) {
                            RuntimeBehaviorSettingsView(projectCWD: projectCWD)
                        }
                        settingsDivider(accent: .tronPurple)
                        settingsLink(
                            "Custom Models",
                            summary: "Saved model definitions and aliases",
                            icon: "slider.horizontal.3",
                            accent: .tronPurple
                        ) { CustomModelsSettingsView() }
                    }

                    TronSettingsGroup("Workspace & Diagnostics", accent: .tronBlue) {
                        settingsLink(
                            "Resource Paths",
                            summary: "Instructions, skills, and project resources",
                            icon: "folder.badge.gearshape",
                            accent: .tronBlue
                        ) {
                            ResourceSettingsView(projectCWD: projectCWD)
                        }
                        settingsDivider(accent: .tronBlue)
                        settingsLink(
                            "Packages and Resources",
                            summary: "Installed packages and executable resources",
                            icon: "shippingbox",
                            accent: .tronBlue
                        ) {
                            PackagesSettingsView(projectCWD: projectCWD)
                        }
                        if scope == .project {
                            settingsDivider(accent: .tronBlue)
                            settingsLink(
                                "Project Trust",
                                summary: "Review executable workspace resource trust",
                                icon: "checkmark.shield",
                                accent: .tronBlue
                            ) {
                                TrustSettingsView(
                                    target: projectCWD.flatMap(TrustTarget.init(cwd:))
                                )
                            }
                        }
                        if scope == .dashboard {
                            settingsDivider(accent: .tronBlue)
                            settingsLink(
                                "Import",
                                summary: "Restore a session export",
                                icon: "tray.and.arrow.down",
                                accent: .tronBlue
                            ) {
                                ImportSettingsView(onImported: onImported)
                            }
                        }
                        settingsDivider(accent: .tronBlue)
                        settingsLink(
                            "Logs",
                            summary: "Recent diagnostics from paired Mac gateways",
                            icon: "text.alignleft",
                            accent: .tronBlue
                        ) {
                            GatewayLogsSettingsView()
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

struct TronProgressiveSheetLink<Label: View, Destination: View>: View {
    let accessibilityLabel: String
    /// Keep destination construction inside the presented sheet so large
    /// settings payloads are not built while the parent sheet is scrolling.
    let destination: () -> Destination
    let label: Label
    let accent: Color?
    @State private var isPresented = false
    @Environment(\.tronSettingsVisualTheme) private var inheritedTheme

    init(
        accessibilityLabel: String,
        accent: Color? = nil,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accent = accent
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .tronManagedSheet(
                isPresented: $isPresented,
                identity: "settings.\(accessibilityLabel)"
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
