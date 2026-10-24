import SwiftUI
import TronMobileCore

/// Settings: this Mac's defaults, its accounts and resources, and this iPhone.
/// A chat's own settings (and its project's) are in Manage Session, next to the
/// chat they apply to. Every destination is one row; each group is one card.
struct SettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    #if HOSTED_TEST
    @Environment(\.hostedIntegrationPresentationTrace) private var hostedTrace
    #endif
    @PresentationState private var showsNotifications = false
    /// Connected Services sheet routes live here, above its presented content,
    /// which SwiftUI can rebuild while the sheet stays up (#932).
    @PresentationState private var integrationRoutes = IntegrationSheetRoutes()
    @PresentationState private var hasRefreshedNotificationBadge = false

    init(onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }) {
        self.onImported = onImported
    }

    private var sections: [SettingsRendererSection] {
        model.settingsSnapshot(for: SettingsTarget.global.gatewayTarget).map { SettingsRendererView.sections($0.resolution) } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    SettingsGroupCard(.iphone) {
                        settingsLink("Appearance", summary: "Theme, type scale, and visual preferences",
                                     icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                        TronSettingsDivider()
                        settingsLink("App Customizations", summary: "Dashboard, visible servers, and subagent activity",
                                     icon: "slider.horizontal.2.square") { AppLocalBehaviorSettingsView() }
                    }
                    SettingsGroupCard(.accounts) {
                        settingsLink("Connections", summary: "Paired Macs and authorized devices", icon: "desktopcomputer") {
                            ConnectionsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Model Providers", summary: "Provider accounts and sign-in", icon: "key") {
                            ProvidersSettingsView(sessionID: nil)
                        }
                        TronSettingsDivider()
                        settingsLink("Connected Services", summary: "Service accounts and Knowledge settings", icon: "link",
                                     onDismiss: { integrationRoutes.reset() }) {
                            IntegrationsSettingsView(routes: integrationRoutes, onOpenSession: onImported)
                        }
                    }
                    SettingsGroupCard(.agent) {
                        SettingsSectionLinks(ids: ["model", "workers", "context"], sections: sections, target: SettingsTarget.global.gatewayTarget, writeLayer: "global")
                        TronSettingsDivider()
                        settingsLink("Trusted Projects", summary: "Projects whose extensions and hooks load", icon: "checkmark.shield") { TrustedProjectsSettingsView() }
                        TronSettingsDivider()
                        SettingsSectionLinks(ids: ["approvals", "run"], sections: sections,
                                             target: SettingsTarget.global.gatewayTarget, writeLayer: "global",
                                             selection: .allExcept(TrustedProjectsSettingsView.keys))
                    }
                    SettingsGroupCard(.tools) {
                        SettingsSectionLinks(ids: ["tools"], sections: sections, target: SettingsTarget.global.gatewayTarget, writeLayer: "global")
                        TronSettingsDivider()
                        settingsLink("MCP Servers", summary: "Tool providers and their sign-ins", icon: "server.rack") {
                            MCPServersSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Extensions", summary: "Packages, built-ins, and themes", icon: "shippingbox") {
                            ExtensionsSettingsView(projectCWD: nil)
                        }
                        TronSettingsDivider()
                        settingsLink("Hooks", summary: "Event handlers extensions register", icon: "bolt.horizontal.circle") {
                            HooksSettingsView(projectCWD: nil)
                        }
                    }
                    let placed = SettingsGroupKind.placedSections
                    let unplaced = sections.filter { !placed.contains($0.id) }
                    if !unplaced.isEmpty {
                        SettingsGroupCard(.more) {
                            SettingsSectionLinks(ids: unplaced.map(\.id), sections: sections,
                                                 target: SettingsTarget.global.gatewayTarget, writeLayer: "global")
                        }
                    }
                    // Utilities and diagnostics that span this iPhone and the
                    // Mac: a shell on the Mac, prototypes, logs and setup. Each
                    // row's summary names its own scope, so the group has no
                    // caption (#1030).
                    SettingsGroupCard(.diagnostics) {
                        MacTerminalSettingsRow()
                        TronSettingsDivider()
                        settingsLink("Push Notifications", summary: "Agent alerts on this iPhone", icon: "bell.badge") {
                            PushNotificationsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Setup", summary: "Import, session storage, telemetry, and prototypes", icon: "gearshape.2") {
                            SetupSettingsView(onImported: onImported)
                        }
                        TronSettingsDivider()
                        settingsLink("Logs", summary: "Diagnostics from this iPhone and your Macs", icon: "text.alignleft") {
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    NotificationInboxToolbarButton(
                        unreadCount: model.notificationInbox.unreadCount,
                        action: { showsNotifications = true }
                    )
                    SettingsChangesLink(scope: .all, onOpenSession: onImported)
                        .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Global Settings") }
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
        .task(id: PresentationActivityTaskID(source: model.settingsFreshness,
                                             presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            try? await model.refreshSettingsSnapshot(for: SettingsTarget.global.gatewayTarget)
        }
        .task(id: presentationActivity.allowsPresentationPublication) {
            guard presentationActivity.allowsPresentationPublication,
                  !hasRefreshedNotificationBadge else { return }
            // Only the root-owned badge is refreshed here. Destination owners
            // load their own data after the sheet transition, keeping unrelated
            // network publications out of the presentation path.
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

    private func settingsLink<Destination: View>(
        _ title: String,
        summary: String,
        icon: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, onDismiss: onDismiss, destination: destination) {
            TronSettingsRow(icon: icon, title: title, subtitle: summary, subtitleColor: .tronTextSecondary)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("settings-link-\(title)")
    }
}

/// The settings palette: each group is one titled card with one accent, and every
/// sheet a row opens keeps that accent. Groups follow what is being configured:
/// the Macs and accounts Tron reaches, the agent's behaviour and what it can use,
/// with this iPhone first and System last.
enum SettingsGroupKind {
    case agent, tools, accounts, more, iphone, diagnostics

    var title: String {
        switch self {
        case .agent: "Agent"
        case .tools: "Tools & Extensions"
        case .accounts: "Accounts"
        case .more: "More"
        case .iphone: "This iPhone"
        case .diagnostics: "System"
        }
    }

    @MainActor var accent: Color {
        switch self {
        case .agent: .tronPurple
        case .tools: .tronCyan
        case .accounts: .tronIndigo
        case .more, .iphone: .tronPrimary
        case .diagnostics: .tronSlate
        }
    }

    /// Schema sections Settings places itself; any other served section joins More.
    /// Sources and setup are shown inside Extensions and Setup.
    static let placedSections: Set<String> = ["model", "workers", "context", "approvals", "run", "trust", "connections", "tools", "sources", "setup"]

    static func icon(forSection id: String) -> String {
        switch id {
        case "model": "cpu"
        case "context": "rectangle.compress.vertical"
        case "run": "arrow.clockwise"
        case "workers": "person.2"
        case "advanced": "gearshape.2"
        case "tools": "wrench.and.screwdriver"
        case "sources": "shippingbox"
        case "setup": "gearshape.2"
        default: "slider.horizontal.3"
        }
    }
}

/// One group's titled card, its rows and every sheet they open in its accent.
struct SettingsGroupCard<Content: View>: View {
    let kind: SettingsGroupKind
    @ViewBuilder let content: () -> Content

    init(_ kind: SettingsGroupKind, @ViewBuilder content: @escaping () -> Content) {
        self.kind = kind; self.content = content
    }

    var body: some View {
        TronSettingsGroup(kind.title, accent: kind.accent) { content() }
            .tronSettingsVisualTheme(accent: kind.accent)
    }
}

/// The rows for served schema sections, in the given order: each opens the
/// section's sheet for one target. A section the target does not serve has no row.
struct SettingsSectionLinks: View {
    let ids: [String]
    let sections: [SettingsRendererSection]
    let target: JSONValue
    var writeLayer: String?
    var ownedLayers: [String] = []
    var projectCWD: String?
    var showsSummary = false
    var selection: SettingsKeySelection = .all
    var homeProfileID: String?
    @Environment(AppModel.self) private var model

    // Presentation grouping only: schema keys, layers and mutation owners stay unchanged.
    private var chatScope: Bool { target.objectValue?["kind"]?.stringValue == "session" }
    private func root(_ id: String) -> String {
        if chatScope && ["model", "workers"].contains(id) { return "advanced" }
        return id == "workers" ? "model" : ["approvals", "run"].contains(id) ? "advanced" : id
    }
    private func members(_ id: String) -> [SettingsRendererSection] {
        let ids = id == "model" ? ["model", "workers"] : id == "advanced" ? (chatScope ? ["model", "workers", "approvals", "run"] : ["approvals", "run"]) : [id]
        return ids.compactMap { id in sections.first { $0.id == id } }.filter { section in
            model.settingsSnapshot(for: target)?.resolution.keys.contains { $0.group == section.id && selection.includes($0) } == true
        }
    }
    private func title(_ id: String) -> String {
        id == "model" ? "Models" : id == "advanced" ? "More Settings" : (sections.first { $0.id == id }?.title ?? id)
    }

    /// A grouped row (Models, More Settings) names its sections in one short
    /// line; joining each section's served description would wrap.
    private func sectionDescription(_ id: String) -> String? {
        let members = members(id)
        if id == "advanced" { return chatScope ? "Workers, connection, retries, and approvals" : "Connection, retries, and approvals" }
        if id == "model", homeProfileID != nil { return "Workers and delegation" }
        if members.count > 1, id == "model" { return "Models, thinking, and workers" }
        let text = members.compactMap(\.description).joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    var body: some View {
        let shown = ids.map(root).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.filter { !members($0).isEmpty }
        ForEach(Array(shown.enumerated()), id: \.element) { index, id in
            if index > 0 { TronSettingsDivider() }
            TronProgressiveSheetLink(accessibilityLabel: title(id), identity: "settings.section.\(id)") {
                ScrollView {
                    TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                        ForEach(members(id)) { section in
                            if section.id == "workers", let homeProfileID,
                               let keys = model.settingsSnapshot(for: target)?.resolution.keys.filter({ $0.group == "workers" }) {
                                HomeTaskSheet(permissionsFor: homeProfileID, title: section.title, settings: AnyView(
                                    SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                        projectCWD: projectCWD, presentation: .keys(keys.map(\.key)), detailedKeys: true, selection: selection)
                                ))
                            } else {
                                SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                    projectCWD: projectCWD, presentation: .section(section.id), embedded: true, selection: selection)
                            }
                        }
                    }.padding(20)
                }
                .tronScrollEdgeChrome()
                .tronNavigationTitle(title(id))
            } label: {
                TronSettingsRow(icon: SettingsGroupKind.icon(forSection: id), title: title(id),
                                subtitle: showsSummary ? (summary(id) ?? sectionDescription(id)) : sectionDescription(id),
                                subtitleColor: .tronTextSecondary)
            }
            .accessibilityIdentifier("settings-section-\(id)-open")
        }
    }

    /// A scope's drill-in row names what it currently uses: the root section's
    /// essential values (Home's model and thinking), then any grouped section's title.
    /// An unset optional value (a context window with no override) uses nothing.
    private func summary(_ id: String) -> String? {
        let sections = members(id)
        guard let first = sections.first, first.id == id else { return nil }
        let values = model.settingsSnapshot(for: target)?.resolution.keys
            .filter { $0.group == id && selection.includes($0) && $0.presentation?.importance == "essential" && $0.value != nil }
            .map(\.display).filter { !$0.isEmpty } ?? []
        guard !values.isEmpty else { return nil }
        return (values + sections.dropFirst().map(\.title)).joined(separator: " · ")
    }
}

/// Scope-owned editors and read-only effective configuration share the Gateway schema.
/// Home edits its durable profile, never silently a current-chapter Session override.
struct SessionSettingsView: View {
    let sessionID: String
    /// The layers this chat writes, in order of preference.
    let ownedLayers: [String]
    var projectCWD: String?
    /// Only Home owns delegation scopes; ordinary chats keep the same schema renderer.
    var homeProfileID: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity

    private var target: JSONValue {
        homeProfileID == nil ? SettingsTarget.sessionGatewayTarget(sessionID) : .object(["kind": .string("home")])
    }
    private var selection: SettingsKeySelection {
        .sessionOverridesExcept(ManageModelConfigurationCard.keys)
    }

    var body: some View {
        let sections = model.settingsSnapshot(for: target).map { SettingsRendererView.sections($0.resolution) } ?? []
        let shown = Set(sections.filter { section in
            model.settingsSnapshot(for: target)?.resolution.keys.contains { $0.group == section.id && selection.includes($0) } == true
        }.map(\.id))
        let rows = (homeProfileID == nil ? ["context", "model", "workers", "approvals", "run", "tools"] : ["workers", "approvals", "run", "tools"])
            .filter(shown.contains)
        // The chat's project, read-only, below its own choices; Manage Session's
        // Workspace row already names the branch. Its notices are listed there once.
        let project = homeProfileID == nil ? projectCWD.flatMap { cwd in
            model.selectedGatewayProfileID().map { (cwd: cwd, profileID: $0) }
        }.flatMap { $0.cwd.isEmpty ? nil : $0 } : nil
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                // Global Settings' layout: titled group cards of drill-in rows (#1651).
                TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                    TronSettingsCaption(homeProfileID == nil
                        ? "Choices for this session. Revert an override to use Global settings."
                        : "Home's overrides of Global settings. Worker launch choices apply to new workers.").containerValue(\.tronSettingsSection, false)
                    if project == nil, let notice = model.settingsSnapshot(for: target)?.resolution.projectNotice {
                        SettingsProjectNoticeGroup(notice: notice)
                    }
                    if sections.isEmpty {
                        TronSheetLoadingState(label: "Loading settings…")
                    } else {
                        if project == nil {
                            TronSettingsGroup("Settings", accent: .tronPrimary) { links(rows, sections) }
                                .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(homeProfileID == nil ? "session-settings-content" : "home-settings-content")
                if let project {
                    ProjectSettingsSections(cwd: project.cwd, profileID: project.profileID, showsWorkspace: false,
                                            sessionSettings: AnyView(links(rows, sections)))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("session-project-settings")
                }
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .task(id: PresentationActivityTaskID(source: model.settingsFreshness,
                                             presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            try? await model.refreshSettingsSnapshot(for: target)
        }
    }

    private func links(_ ids: [String], _ sections: [SettingsRendererSection]) -> some View {
        SettingsSectionLinks(ids: ids, sections: sections, target: target, ownedLayers: ownedLayers, projectCWD: projectCWD,
                             showsSummary: true, selection: selection, homeProfileID: homeProfileID)
    }
}

/// Why the Project layer is not applied (untrusted or unreadable), in Session and Project settings.
struct SettingsProjectNoticeGroup: View {
    let notice: SettingsProjectNotice

    var body: some View {
        TronSettingsGroup(nil, detail: notice.file) { TronSettingsNotice(message: notice.message) }
    }
}

/// Project Settings' notice and the repository fields the Gateway ignores, named
/// by the setting they try to change. Listed once here, not on every Session.
struct SettingsProjectNotices: View {
    let resolution: SettingsResolution

    var body: some View {
        if let notice = resolution.projectNotice { SettingsProjectNoticeGroup(notice: notice) }
        if !resolution.diagnostics.isEmpty {
            TronSettingsGroup("Ignored settings", detail: resolution.diagnostics.first?.file) {
                ForEach(Array(resolution.diagnostics.enumerated()), id: \.offset) { index, diagnostic in
                    if index > 0 { TronSettingsDivider() }
                    let label = resolution.keys.first { $0.key == diagnostic.key }?.presentation?.label
                    TronSettingsRow(icon: "info.circle", title: label ?? diagnostic.path,
                                    subtitle: diagnostic.reason == "project-forbidden"
                                        ? "Project settings can't change this. Ignored: \(diagnostic.path)"
                                        : "Not a setting Tron knows. Ignored.")
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-ignored-\(diagnostic.path)")
                }
                if resolution.diagnosticsTruncated {
                    TronSettingsDivider()
                    TronSettingsRow(icon: "ellipsis", title: "More ignored settings",
                                    subtitle: "Only the first ones are listed.")
                }
            }
        }
    }
}

/// Only admitted, applied repository values; never a Global inspection clone.
struct SettingsProjectGroups: View {
    let target: JSONValue
    var selection: SettingsKeySelection = .projectValues
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.settingsSnapshot(for: target) {
            ForEach(SettingsRendererView.sections(snapshot.resolution).filter { section in
                snapshot.resolution.keys.contains { $0.group == section.id && selection.includes($0) }
            }) { section in
                SettingsRendererView(target: target, writeLayer: nil, presentation: .section(section.id),
                                     embedded: true, selection: selection)
            }
        } else { TronSheetLoadingState(label: "Loading Project settings…") }
    }
}

/// Setup: import, Mac storage/telemetry, and safeguarded local prototypes.
struct SetupSettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) {
                TronSettingsGroup("Import", detail: "Open a Tron session export in a new session.") {
                    ImportSessionRow(onImported: onImported)
                }
                SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "global",
                                     presentation: .section("setup"), embedded: true)
                ExperimentalSettingsContent()
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Setup")
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
    let surfaceAccent: Color?
    /// Settings destinations open at medium and expand to large; a destination
    /// that publishes `TronSheetFitHeightKey` (the model picker) passes `.contentFit`.
    let detents: TronSheetDetentPolicy
    /// Runs once the destination sheet has actually been dismissed.
    let onDismiss: (() -> Void)?
    /// The link's call site, so two links sharing a label keep separate state.
    private let fileID: String
    private let line: Int
    /// Kept in the enclosing presentation's scope by identity, so a link inside
    /// a sheet whose content SwiftUI rebuilds keeps its sheet open (#1073).
    @PresentationState private var isPresented: Bool
    @Environment(\.tronSettingsVisualTheme) private var inheritedTheme

    init(
        accessibilityLabel: String,
        identity: String? = nil,
        accent: Color? = nil,
        surfaceAccent: Color? = nil,
        detents: TronSheetDetentPolicy = .fixed([.medium, .large]),
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
        self.detents = detents
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
                        // A field's source/reset projection belongs to that row,
                        // never to rows in its separately owned destination.
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
                .modifier(TronSheetDetentPolicyModifier(policy: detents))
                .presentationDragIndicator(.hidden)
            }
    }

    /// A destination keeps its presenter's family accent unless the link names one.
    /// The theme wraps the Done too, so it takes the same tint as the title (#963).
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
