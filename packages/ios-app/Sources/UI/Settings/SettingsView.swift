import SwiftUI

/// Where Settings was opened from. Settings orders its content from the most
/// specific scope to the most general: this chat (or Home), its project, then
/// the Mac defaults every chat inherits, then this iPhone.
enum SettingsContext: Equatable {
    case dashboard
    case chat(sessionID: String, projectCWD: String?)
    case home(sessionID: String)
}

struct SettingsView: View {
    let context: SettingsContext
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
    @State private var browsingProjects = false
    @State private var pickedProject: String?
    @State private var projectRoute: ProjectSettingsRoute?

    init(context: SettingsContext = .dashboard, onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }) {
        self.context = context
        self.onImported = onImported
    }

    private var changesScope: SettingsChangesScope {
        switch context {
        case .dashboard: .all
        case .chat(let sessionID, let cwd): .session(sessionID, projectCWD: cwd)
        case .home(let sessionID): .home(sessionID)
        }
    }

    /// This chat's or Home's own settings, then the project's (or the project picker).
    @ViewBuilder
    private var scopedSettings: some View {
        switch context {
        case .chat(let sessionID, let cwd):
            SettingsRendererView(
                target: .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                writeLayer: "chat", embedded: true, ownedLayers: ["chat"],
                externalControlKeys: ["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow", "tools.active"],
                projectCWD: cwd, presentation: .overridesLink(scope: "this chat", title: "This Chat", icon: "bubble.left.and.text.bubble.right")
            )
            if let cwd, !cwd.isEmpty, let profileID = model.selectedGatewayProfileID() {
                TronGlassCard(accent: .tronEmerald) { ProjectSettingsLink(cwd: cwd, profileID: profileID) }
            }
        case .home(let sessionID):
            SettingsRendererView(
                target: .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                writeLayer: nil, embedded: true, ownedLayers: ["chat", "profile"],
                externalControlKeys: ["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow"],
                presentation: .overridesLink(scope: "Home", title: "Home", icon: "house")
            )
        case .dashboard:
            TronGlassCard(accent: .tronEmerald) {
                Button { browsingProjects = true } label: {
                    TronSettingsRow(icon: "folder.badge.gearshape", title: "Projects",
                                    subtitle: "Choose a workspace to see what it sets", subtitleColor: .tronTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-projects")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    SettingsChangesLink(scope: changesScope, subtitle: "What agents changed, and approvals waiting for you",
                                        onOpenSession: onImported)
                        .tronGlassSurface(accent: .tronEmerald)
                    scopedSettings
                    if context != .dashboard {
                        TronSettingsDetailText("Defaults on this Mac. Everything above takes precedence.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Each renderer keeps its own target; opening Settings never changes scope.
                    SettingsRendererView(
                        target: .object(["kind": .string("mac")]),
                        writeLayer: "mac",
                        embedded: true,
                        externalControlKeys: ["sources.packages"],
                        sectionSupplement: { sectionSupplement($0) },
                        sectionSubtitle: { section in
                            switch section {
                            case "accounts": "Model providers, custom models, and connected services"
                            case "setup": "Connections, import, and logs"
                            default: nil
                            }
                        },
                        unresolvedSupplement: AnyView(offlineDestinations)
                    )

                    // Like every top-level group: one row, its destinations in the sub-sheet.
                    TronGlassCard(accent: .tronEmerald) {
                        settingsLink("This iPhone", summary: "Appearance and sessions. Stored on this iPhone only.",
                                     icon: "iphone", accent: .tronEmerald) {
                            ScrollView {
                                TronGlassCard(accent: .tronEmerald) {
                                    settingsLink("Appearance", summary: "Theme, type scale, and visual preferences",
                                                 icon: "circle.lefthalf.filled", accent: .tronEmerald) {
                                        AppearanceSettingsView()
                                    }
                                    settingsDivider(accent: .tronEmerald)
                                    settingsLink("Sessions", summary: "Dashboard list and subagent activity",
                                                 icon: "slider.horizontal.2.square", accent: .tronEmerald) {
                                        AppLocalBehaviorSettingsView()
                                    }
                                }
                                .tronSettingsCaption("Stored on this iPhone. Never changes harness behaviour.")
                                .padding(20)
                            }
                            .tronScrollEdgeChrome()
                            .tronNavigationTitle("This iPhone")
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
        // Projects: pick a workspace, then open its settings once the picker is gone.
        .tronManagedSheet(isPresented: $browsingProjects, identity: "settings.projects", onDismiss: {
            defer { pickedProject = nil }
            guard let cwd = pickedProject, let profileID = model.selectedGatewayProfileID() else { return }
            projectRoute = ProjectSettingsRoute(cwd: cwd, profileID: profileID)
        }) {
            WorkspaceBrowser(initialPath: model.defaultWorkspace) { pickedProject = $0 }
        }
        .tronManagedSheet(item: $projectRoute, identity: { "settings.project.\($0.id)" }) { route in
            ProjectSettingsSheet(route: route)
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
            if let rows = sectionSupplement("tools") { TronSettingsGroup("Tools", accent: SettingsSectionStyle("tools").accent) { rows }.tronSettingsVisualTheme(accent: SettingsSectionStyle("tools").accent) }
            if let rows = sectionSupplement("permissions") { TronSettingsGroup("Permissions", accent: SettingsSectionStyle("permissions").accent) { rows }.tronSettingsVisualTheme(accent: SettingsSectionStyle("permissions").accent) }
            if let rows = sectionSupplement("run") { TronSettingsGroup("Run", accent: SettingsSectionStyle("run").accent) { rows }.tronSettingsVisualTheme(accent: SettingsSectionStyle("run").accent) }
            if let rows = sectionSupplement("accounts") { TronSettingsGroup("Accounts", accent: SettingsSectionStyle("accounts").accent) { rows }.tronSettingsVisualTheme(accent: SettingsSectionStyle("accounts").accent) }
            if let rows = sectionSupplement("sources") { TronSettingsGroup("Sources", accent: SettingsSectionStyle("sources").accent) { rows }.tronSettingsVisualTheme(accent: SettingsSectionStyle("sources").accent) }
            if let rows = sectionSupplement("setup") { TronSettingsGroup("Setup", accent: SettingsSectionStyle("setup").accent) { rows }.tronSettingsVisualTheme(accent: SettingsSectionStyle("setup").accent) }
        }
    }

    /// Native flows keep their established controls inside the schema's section.
    /// Harness values (including default trust) have just one generic editor.
    /// Rows take their section's accent from the renderer; nil means none.
    private func sectionSupplement(_ section: String) -> AnyView? {
        switch section {
        case "tools":
            AnyView(settingsLink("MCP Servers", summary: "Tool providers and authentication",
                                 icon: "server.rack", accent: .tronCyan) {
                MCPServersSettingsView(projectCWD: nil, sessionID: nil)
            })
        case "run":
            AnyView(settingsLink("Hooks", summary: "Loaded event handlers from extensions",
                                 icon: "bolt.horizontal.circle", accent: .tronAmber) {
                HooksSettingsView(projectCWD: nil)
            })
        case "accounts":
            AnyView(VStack(spacing: 0) {
                settingsLink("Model Providers", summary: "Provider accounts and authentication",
                             icon: "key", accent: .tronPurple) { ProvidersSettingsView(sessionID: nil) }
                settingsDivider(accent: .tronPurple)
                settingsLink("Custom Models", summary: "Saved model definitions and aliases",
                             icon: "slider.horizontal.3", accent: .tronPurple) { CustomModelsSettingsView() }
                settingsDivider(accent: .tronPurple)
                settingsLink("Connected Services", summary: "Accounts and service capabilities",
                             icon: "link", accent: .tronPurple) { IntegrationsSettingsView() }
            })
        case "sources":
            AnyView(settingsLink("Extensions", summary: "Installed packages and what they contribute",
                                 icon: "shippingbox", accent: .tronCyan) { ExtensionsSettingsView(projectCWD: nil) })
        case "setup":
            AnyView(VStack(spacing: 0) {
                settingsLink("Connections", summary: "Pair Macs, devices, and push readiness",
                             icon: "desktopcomputer", accent: .tronBlue) { ConnectionsSettingsView() }
                settingsDivider(accent: .tronBlue)
                settingsLink("Import", summary: "Restore a session export",
                             icon: "tray.and.arrow.down", accent: .tronBlue) { ImportSettingsView(onImported: onImported) }
                settingsDivider(accent: .tronBlue)
                settingsLink("Logs", summary: "Recent diagnostics from paired Mac gateways",
                             icon: "text.alignleft", accent: .tronBlue) { GatewayLogsSettingsView() }
            })
        default:
            nil
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
        .accessibilityIdentifier("settings-link-\(title)")
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
    /// Settings destinations open at medium and expand to large; a destination
    /// that publishes `TronSheetFitHeightKey` (the model picker) passes `.contentFit`.
    let detents: TronSheetDetentPolicy
    @State private var isPresented = false
    @Environment(\.tronSettingsVisualTheme) private var inheritedTheme

    init(
        accessibilityLabel: String,
        identity: String? = nil,
        accent: Color? = nil,
        detents: TronSheetDetentPolicy = .fixed([.medium, .large]),
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
