import SwiftUI
import TronMobileCore

struct SettingsView: View {
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var showsNotifications = false
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
                        settingsLink("Appearance", summary: "Dashboard, activity, theme, and fonts",
                                     icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                    }
                    SettingsGroupCard(.accounts) {
                        settingsLink("Connections", summary: "Paired Macs and authorized devices", icon: "desktopcomputer") {
                            ConnectionsSettingsView()
                        }
                        TronSettingsDivider()
                        settingsLink("Model Providers", summary: "Provider accounts and sign-in", icon: "key") {
                            ProvidersSettingsView(sessionID: nil)
                        }
                    }
                    SettingsGroupCard(.tools) {
                        TronProgressiveSheetLink(accessibilityLabel: "Agent Behavior") {
                            GlobalAgentBehaviorView()
                        } label: {
                            TronSettingsRow(icon: "slider.horizontal.3", title: "Agent Behavior",
                                            subtitle: "Models, compaction, trust, and more")
                        }
                        .accessibilityIdentifier("settings-link-Agent Behavior")
                        TronSettingsDivider()
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

enum SettingsGroupKind {
    case tools, accounts, more, iphone, diagnostics

    var title: String {
        switch self {
        case .tools: "Agent & Tools"
        case .accounts: "Accounts"
        case .more: "More"
        case .iphone: "This iPhone"
        case .diagnostics: "System"
        }
    }

    @MainActor var accent: Color {
        switch self {
        case .tools, .accounts, .more, .iphone: .tronPrimary
        case .diagnostics: .tronSteel
        }
    }

    static let placedSections: Set<String> = ["model", "workers", "context", "run", "trust", "connections", "tools", "sources", "setup"]

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

struct GlobalAgentBehaviorView: View {
    private let target = SettingsTarget.global.gatewayTarget

    var body: some View {
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) {
                ForEach(["model", "workers", "context"], id: \.self) { section in
                    SettingsRendererView(target: target, writeLayer: "global", presentation: .section(section), embedded: true,
                                         showsGroupHeadings: true)
                }
                TrustedProjectsSettingsView()
                SettingsRendererView(target: target, writeLayer: "global", presentation: .section("run"), embedded: true,
                                     showsGroupHeadings: true, selection: .allExcept(TrustedProjectsSettingsView.keys))
            }.padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Agent Behavior")
    }
}

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

struct SettingsSectionLinks: View {
    let ids: [String]
    let sections: [SettingsRendererSection]
    let target: JSONValue
    var writeLayer: String?
    var ownedLayers: [String] = []
    var projectCWD: String?
    var showsSummary = false
    var selection: SettingsKeySelection = .all
    @Environment(AppModel.self) private var model

    private var chatScope: Bool { target.objectValue?["kind"]?.stringValue == "session" }
    private func root(_ id: String) -> String {
        if chatScope && ["model", "workers"].contains(id) { return "advanced" }
        return id == "workers" ? "model" : id == "run" ? "advanced" : id
    }
    private func members(_ id: String) -> [SettingsRendererSection] {
        let ids = id == "model" ? ["model", "workers"] : id == "advanced" ? (chatScope ? ["model", "workers", "run"] : ["run"]) : [id]
        return ids.compactMap { id in sections.first { $0.id == id } }.filter { section in
            model.settingsSnapshot(for: target)?.resolution.keys.contains { $0.group == section.id && selection.includes($0) } == true
        }
    }
    private func title(_ id: String) -> String {
        id == "model" ? "Models" : id == "advanced" ? "More Settings" : (sections.first { $0.id == id }?.title ?? id)
    }

    private func sectionDescription(_ id: String) -> String? {
        let members = members(id)
        if id == "advanced" { return chatScope ? "Workers and connection" : "Connection" }
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
                            SettingsRendererView(target: target, writeLayer: writeLayer, ownedLayers: ownedLayers,
                                projectCWD: projectCWD, presentation: .section(section.id), embedded: true, selection: selection)
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
            .tronListMarkers("settings-section-\(id)-open")
        }
    }

    private func summary(_ id: String) -> String? {
        let sections = members(id)
        guard let first = sections.first, first.id == id else { return nil }
        let values = model.settingsSnapshot(for: target)?.resolution.keys
            .filter { $0.group == id && selection.includes($0) && $0.presentation.importance == "essential" && $0.value != nil }
            .map(\.display).filter { !$0.isEmpty } ?? []
        guard !values.isEmpty else { return nil }
        return (values + sections.dropFirst().map(\.title)).joined(separator: " · ")
    }
}

struct SessionSettingsView: View {
    let sessionID: String
    let ownedLayers: [String]
    var projectCWD: String?
    var homeProfileID: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var scrollPosition = ScrollPosition(edge: .top)
    @PresentationState private var userScrolled = false

    private var target: JSONValue {
        homeProfileID == nil ? SettingsTarget.sessionGatewayTarget(sessionID) : .object(["kind": .string("home")])
    }
    private var selection: SettingsKeySelection {
        .sessionOverridesExcept(ManageModelConfigurationCard.keys)
    }
    static let sessionCaption = "Choices for this session. Revert an override to use Global settings."

    var body: some View {
        let sections = model.settingsSnapshot(for: target).map { SettingsRendererView.sections($0.resolution) } ?? []
        let shown = Set(sections.filter { section in
            model.settingsSnapshot(for: target)?.resolution.keys.contains { $0.group == section.id && selection.includes($0) } == true
        }.map(\.id))
        let rows = (homeProfileID == nil ? ["context", "tools", "model", "workers", "run"] : ["workers", "tools", "run"])
            .filter(shown.contains)
        let moreRows = rows.filter { ["model", "workers", "run"].contains($0) }
        let project = homeProfileID == nil ? projectCWD.flatMap { cwd in
            model.selectedGatewayProfileID().map { (cwd: cwd, profileID: $0) }
        }.flatMap { $0.cwd.isEmpty ? nil : $0 } : nil
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                TronSettingsSections(alignment: .leading, spacing: 18) {
                    if homeProfileID != nil {
                        TronSettingsCaption("Home's overrides of Global settings. Worker launch choices apply to new workers.")
                            .containerValue(\.tronSettingsSection, false)
                    }
                    if project == nil, let notice = model.settingsSnapshot(for: target)?.resolution.projectNotice {
                        SettingsProjectNoticeGroup(notice: notice)
                    }
                    if sections.isEmpty {
                        TronSheetLoadingState(label: "Loading settings…")
                    } else if let homeProfileID {
                        homeSections(rows, sections, profileID: homeProfileID)
                        HomeControlsSection(profileID: homeProfileID)
                    } else if project == nil {
                        TronSettingsGroup(nil, accent: .tronPrimary) { links(rows, sections) }
                            .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
                        TronSettingsCaption(Self.sessionCaption).containerValue(\.tronSettingsSection, false)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(homeProfileID == nil ? "session-settings-content" : "home-settings-content")
                if let project {
                    ProjectSettingsSections(cwd: project.cwd, profileID: project.profileID, showsWorkspace: false,
                                            sessionSettings: AnyView(links(rows.filter { !moreRows.contains($0) }, sections)),
                                            sessionSettingsAfterTrust: moreRows.isEmpty ? nil : AnyView(links(moreRows, sections)),
                                            sessionSettingsFooter: Self.sessionCaption)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("session-project-settings")
                }
            }
            .padding(20)
        }
        .scrollPosition($scrollPosition)
        .onScrollPhaseChange { _, phase in if phase == .interacting { userScrolled = true } }
        .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentInsets.top, $0.contentOffset.y] } action: { _, value in
            let top = -value[0]
            if !userScrolled, value[1] != top, abs(value[1] - top) < 1 { scrollPosition.scrollTo(y: 0) }
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
                             showsSummary: true, selection: selection)
    }

    private func homeSections(_ ids: [String], _ sections: [SettingsRendererSection], profileID: String) -> some View {
        ForEach(ids, id: \.self) { id in
            if id == "workers", let section = sections.first(where: { $0.id == id }),
               let keys = model.settingsSnapshot(for: target)?.resolution.keys.filter({ $0.group == id }) {
                TronSettingsGroup(section.title) {
                    SettingsRendererView(target: target, writeLayer: nil, ownedLayers: ownedLayers,
                        projectCWD: projectCWD, presentation: .keys(keys.map(\.key)), detailedKeys: true, selection: selection)
                }
                HomeTaskSheet(permissionsFor: profileID)
            } else {
                SettingsRendererView(target: target, writeLayer: nil, ownedLayers: ownedLayers,
                    projectCWD: projectCWD, presentation: .section(id), embedded: true,
                    showsGroupHeadings: true, selection: selection)
            }
        }
    }
}

struct SettingsProjectNoticeGroup: View {
    let notice: SettingsProjectNotice

    var body: some View {
        TronSettingsGroup(nil, detail: notice.file) { TronSettingsNotice(message: notice.message) }
    }
}

struct SettingsProjectNotices: View {
    let resolution: SettingsResolution

    var body: some View {
        if let notice = resolution.projectNotice { SettingsProjectNoticeGroup(notice: notice) }
        if !resolution.diagnostics.isEmpty {
            TronSettingsGroup("Ignored settings", detail: resolution.diagnostics.first?.file) {
                ForEach(Array(resolution.diagnostics.enumerated()), id: \.offset) { index, diagnostic in
                    if index > 0 { TronSettingsDivider() }
                    let label = resolution.keys.first { $0.key == diagnostic.key }?.presentation.label
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
    let destination: () -> Destination
    let label: Label
    let accent: Color?
    let surfaceAccent: Color?
    let detents: TronSheetDetentPolicy
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
