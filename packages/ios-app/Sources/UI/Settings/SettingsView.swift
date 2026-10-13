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
    @State private var showsNotifications = false
    @State private var hasRefreshedNotificationBadge = false

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
                    SettingsGroupCard(.agent) {
                        SettingsSectionLinks(ids: ["model", "context", "run", "permissions"], sections: sections,
                                             target: SettingsTarget.global.gatewayTarget, writeLayer: "mac")
                    }
                    SettingsGroupCard(.tools) {
                        SettingsSectionLinks(ids: ["tools"], sections: sections, target: SettingsTarget.global.gatewayTarget, writeLayer: "mac")
                        TronSettingsDivider()
                        settingsLink("MCP Servers", summary: "Tool providers and their sign-ins", icon: "server.rack") {
                            MCPServersSettingsView(projectCWD: nil, sessionID: nil)
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
                    SettingsGroupCard(.accounts) {
                        settingsLink("Model Providers", summary: "Provider accounts and sign-in", icon: "key") {
                            ProvidersSettingsView(sessionID: nil)
                        }
                        TronSettingsDivider()
                        settingsLink("Custom Models", summary: "Your own model definitions", icon: "slider.horizontal.3") {
                            CustomModelsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Connected Services", summary: "Service accounts and what they offer", icon: "link") {
                            IntegrationsSettingsView()
                        }
                    }
                    SettingsGroupCard(.data) {
                        settingsLink("Connections", summary: "Paired Macs, devices, and push", icon: "desktopcomputer") {
                            ConnectionsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Logs", summary: "Recent diagnostics from your Macs", icon: "text.alignleft") {
                            GatewayLogsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Setup", summary: "Import, session storage, and telemetry", icon: "gearshape.2") {
                            SetupSettingsView(onImported: onImported)
                        }
                    }
                    let placed = SettingsGroupKind.placedSections
                    let unplaced = sections.filter { !placed.contains($0.id) }
                    if !unplaced.isEmpty {
                        SettingsGroupCard(.more) {
                            SettingsSectionLinks(ids: unplaced.map(\.id), sections: sections,
                                                 target: SettingsTarget.global.gatewayTarget, writeLayer: "mac")
                        }
                    }
                    SettingsGroupCard(.iphone, detail: "Stored on this iPhone. Never changes what the agent does.") {
                        settingsLink("Appearance", summary: "Theme, type scale, and visual preferences",
                                     icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                        TronSettingsDivider()
                        settingsLink("Sessions", summary: "Dashboard list and subagent activity",
                                     icon: "slider.horizontal.2.square") { AppLocalBehaviorSettingsView() }
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
                        .tronSettingsVisualTheme(accent: .tronEmerald)
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
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronSettingsRow(icon: icon, title: title, subtitle: summary, subtitleColor: .tronTextSecondary)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("settings-link-\(title)")
    }
}

/// The settings palette: each group is one titled card with one accent, and every
/// sheet a row opens keeps that accent. Groups follow what is being configured:
/// the agent's behaviour, what it can use, the accounts it reaches, this Mac's
/// maintenance, then this iPhone.
enum SettingsGroupKind {
    case agent, tools, accounts, data, more, iphone

    var title: String {
        switch self {
        case .agent: "Agent"
        case .tools: "Tools & Extensions"
        case .accounts: "Accounts"
        case .data: "Data & Diagnostics"
        case .more: "More"
        case .iphone: "This iPhone"
        }
    }

    var accent: Color {
        switch self {
        case .agent: .tronPurple
        case .tools: .tronCyan
        case .accounts: .tronIndigo
        case .data: .tronBlue
        case .more, .iphone: .tronEmerald
        }
    }

    /// Schema sections Settings places itself; any other served section joins More.
    /// Sources and setup are shown inside Extensions and Setup.
    static let placedSections: Set<String> = ["model", "context", "run", "permissions", "tools", "sources", "setup"]

    static func icon(forSection id: String) -> String {
        switch id {
        case "model": "cpu"
        case "context": "rectangle.compress.vertical"
        case "run": "arrow.clockwise"
        case "permissions": "checkmark.shield"
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
    var detail: String?
    @ViewBuilder let content: () -> Content

    init(_ kind: SettingsGroupKind, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.kind = kind; self.detail = detail; self.content = content
    }

    var body: some View {
        TronSettingsGroup(kind.title, detail: detail, accent: kind.accent) { content() }
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

    var body: some View {
        let shown = ids.compactMap { id in sections.first { $0.id == id } }
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, section in
            if index > 0 { TronSettingsDivider() }
            TronProgressiveSheetLink(accessibilityLabel: section.title, identity: "settings.section.\(section.id)") {
                SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                     projectCWD: projectCWD, presentation: .section(section.id))
                    .tronNavigationTitle(section.title)
            } label: {
                TronSettingsRow(icon: SettingsGroupKind.icon(forSection: section.id), title: section.title,
                                subtitle: section.description, subtitleColor: .tronTextSecondary)
            }
            .accessibilityIdentifier("settings-section-\(section.id)-open")
        }
    }
}

/// Every setting one chat uses, opened from Manage Session or Manage Home: the
/// chat's changes, then each section as it applies to the chat. A value carries
/// where it comes from (Chat, Profile, Project, Mac or Built-in); one this chat can
/// set has its control, any other a link to the layer that owns it. Setup and
/// package sources are this Mac's and the project's, so they are not listed here.
struct ChatSettingsView: View {
    let sessionID: String
    /// The layers this chat writes, in order of preference.
    let ownedLayers: [String]
    var projectCWD: String?
    let changesScope: SettingsChangesScope
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity

    private static let chatSections = ["model", "context", "tools", "run", "permissions"]
    private var target: JSONValue { SettingsTarget.sessionGatewayTarget(sessionID) }

    var body: some View {
        let sections = model.settingsSnapshot(for: target).map { SettingsRendererView.sections($0.resolution) } ?? []
        let unplaced = sections.map(\.id).filter { !SettingsGroupKind.placedSections.contains($0) }
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronGlassCard {
                    SettingsChangesLink(scope: changesScope, subtitle: "What agents changed, and approvals waiting for you")
                }
                TronSettingsGroup("Settings", detail: "Each value shows where it comes from: this chat, its project, this Mac, or built in.") {
                    if sections.isEmpty {
                        TronLoadingState(label: "Loading settings…").padding(16)
                    } else {
                        SettingsSectionLinks(ids: Self.chatSections + unplaced, sections: sections, target: target,
                                             writeLayer: nil, ownedLayers: ownedLayers, projectCWD: projectCWD)
                    }
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
}

/// Setup: this Mac's session storage and telemetry, and importing a session.
struct SetupSettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                TronSettingsGroup("Import", detail: "Open a Tron session export in a new session.") {
                    ImportSessionRow(onImported: onImported)
                }
                SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "mac",
                                     presentation: .section("setup"), embedded: true)
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
