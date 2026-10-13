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

    /// The first card: changes, then what is specific to where Settings opened —
    /// this chat and its project, Home, or (from the dashboard) every project.
    @ViewBuilder
    private var scopeRows: some View {
        SettingsChangesLink(scope: changesScope, subtitle: "What agents changed, and approvals waiting for you",
                            onOpenSession: onImported)
        TronSettingsDivider(accent: .tronEmerald)
        switch context {
        case .chat(let sessionID, let cwd):
            scopeLink("This Chat", icon: "bubble.left.and.text.bubble.right", subtitle: "Settings set only for this chat") {
                SettingsRendererView(
                    target: .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    writeLayer: "chat", ownedLayers: ["chat"],
                    externalControlKeys: ["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow", "tools.active"],
                    projectCWD: cwd, presentation: .overrides(scope: "this chat", allTitle: "Override a Setting")
                )
            }
            if let cwd, !cwd.isEmpty, let profileID = model.selectedGatewayProfileID() {
                TronSettingsDivider(accent: .tronEmerald)
                ProjectSettingsLink(cwd: cwd, profileID: profileID)
            }
        case .home(let sessionID):
            scopeLink("Home", icon: "house", subtitle: "Settings set only for Home") {
                SettingsRendererView(
                    target: .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    writeLayer: nil, ownedLayers: ["chat", "profile"],
                    externalControlKeys: ["model.ref[role=chat]", "model.thinking[role=chat]", "model.contextWindow"],
                    presentation: .overrides(scope: "Home", allTitle: "Override a Setting")
                )
            }
        case .dashboard:
            Button { browsingProjects = true } label: {
                TronSettingsRow(icon: "folder.badge.gearshape", title: "Projects",
                                subtitle: "Settings for a chosen workspace", subtitleColor: .tronTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-projects")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    TronGlassCard(accent: .tronEmerald) { scopeRows }
                        .tronSettingsVisualTheme(accent: .tronEmerald)
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
                        unresolvedSupplement: AnyView(offlineDestinations)
                    )
                    TronSettingsGroup("This iPhone", detail: "Stored on this iPhone. Never changes harness behaviour.",
                                      accent: .tronEmerald) {
                        settingsLink("Appearance", summary: "Theme, type scale, and visual preferences",
                                     icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                        TronSettingsDivider(accent: .tronEmerald)
                        settingsLink("Sessions", summary: "Dashboard list and subagent activity",
                                     icon: "slider.horizontal.2.square") { AppLocalBehaviorSettingsView() }
                    }
                    .tronSettingsVisualTheme(accent: .tronEmerald)
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

    /// While the schema cannot load, the hand-built flows (pairing and account
    /// repair among them) stay reachable, in the same family cards.
    private var offlineDestinations: some View {
        VStack(spacing: 18) {
            ForEach(SettingsFamily.allCases, id: \.self) { family in
                let rows = Self.supplementedSections.filter { SettingsSectionStyle($0).family == family }
                    .compactMap { sectionSupplement($0) }
                if !rows.isEmpty {
                    TronSettingsGroup(family.title, accent: family.accent) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { TronSettingsDivider(accent: family.accent) }
                            row
                        }
                    }
                    .tronSettingsVisualTheme(accent: family.accent)
                }
            }
        }
    }

    private static let supplementedSections = ["accounts", "tools", "sources", "setup"]

    /// Native flows keep their established controls inside the schema's section.
    /// Harness values (including default trust) have just one generic editor.
    /// Rows take their family's accent from the presenting card or sheet.
    private func sectionSupplement(_ section: String) -> AnyView? {
        switch section {
        case "tools":
            AnyView(settingsLink("MCP Servers", summary: "Tool providers and authentication", icon: "server.rack") {
                MCPServersSettingsView(projectCWD: nil, sessionID: nil)
            })
        case "accounts":
            AnyView(VStack(spacing: 0) {
                settingsLink("Model Providers", summary: "Provider accounts and authentication", icon: "key") {
                    ProvidersSettingsView(sessionID: nil)
                }
                TronSettingsDivider()
                settingsLink("Custom Models", summary: "Saved model definitions and aliases", icon: "slider.horizontal.3") {
                    CustomModelsSettingsView()
                }
                TronSettingsDivider()
                settingsLink("Connected Services", summary: "Accounts and service capabilities", icon: "link") {
                    IntegrationsSettingsView()
                }
            })
        case "sources":
            AnyView(VStack(spacing: 0) {
                settingsLink("Extensions", summary: "Installed packages and what they contribute", icon: "shippingbox") {
                    ExtensionsSettingsView(projectCWD: nil)
                }
                TronSettingsDivider()
                settingsLink("Hooks", summary: "Loaded event handlers from extensions", icon: "bolt.horizontal.circle") {
                    HooksSettingsView(projectCWD: nil)
                }
            })
        case "setup":
            AnyView(VStack(spacing: 0) {
                settingsLink("Connections", summary: "Pair Macs, devices, and push readiness", icon: "desktopcomputer") {
                    ConnectionsSettingsView()
                }
                TronSettingsDivider()
                settingsLink("Import", summary: "Restore a session export", icon: "tray.and.arrow.down") {
                    ImportSettingsView(onImported: onImported)
                }
                TronSettingsDivider()
                settingsLink("Logs", summary: "Recent diagnostics from paired Mac gateways", icon: "text.alignleft") {
                    GatewayLogsSettingsView()
                }
            })
        default:
            nil
        }
    }

    /// The scope Settings was opened from: opens what that scope itself sets.
    private func scopeLink<Destination: View>(_ title: String, icon: String, subtitle: String,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, identity: "settings.scope.\(title)") {
            destination().tronNavigationTitle(title)
        } label: {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleColor: .tronTextSecondary)
        }
        .accessibilityIdentifier("settings-scope-open")
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        summary: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronSettingsRow(icon: icon, title: title, subtitle: summary, subtitleColor: .tronTextSecondary)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("settings-link-\(title)")
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

    /// A destination keeps its presenter's family accent unless the link names one.
    @ViewBuilder
    private var destinationContent: some View {
        if let resolved = accent ?? inheritedTheme?.accent {
            destination().tronSettingsVisualTheme(accent: resolved)
        } else {
            destination()
        }
    }
}
