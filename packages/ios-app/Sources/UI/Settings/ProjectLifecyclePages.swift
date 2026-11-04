import SwiftUI
import TronMobileCore

/// Disposable presentation data. The lifecycle read owner must supply canonical
/// paths, effective trust and refusal reasons; these views never infer eligibility.
struct ProjectLifecycleProject: Identifiable {
    let name: String
    let path: String
    let displayPath: String
    let trusted: Bool
    var trustUnavailableReason: String?
    var untrustUnavailableReason: String?
    var id: String { path }
}

/// The approved list anatomy and sheet routes, independent of the native RPC.
/// Destinations and effects are required inputs: there is no production fallback.
@MainActor
struct ProjectLifecycleProjectsPage<ProjectDestination: View, AddDestination: View>: View {
    let projects: [ProjectLifecycleProject]
    var identifierPrefix = "project-lifecycle"
    @ViewBuilder let projectDestination: (ProjectLifecycleProject) -> ProjectDestination
    @ViewBuilder let addDestination: () -> AddDestination

    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronPrimary }

    var body: some View {
        ProjectLifecyclePage("Trusted Projects", identifier: "\(identifierPrefix)-list") {
            TronSettingsGroup(nil) {
                SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "global",
                    presentation: .keys([TrustedProjectsSettingsView.policyKey]), detailedKeys: true)
            }
            TronListGroup(sections: [TronListSection(title: "Projects", rows: projects)],
                identifier: "\(identifierPrefix)-list-rows") { item in
                ProjectLifecycleSheetRow(content: TronListRowContent(title: item.name,
                    status: TronListStatus(text: item.trusted ? "Trusted" : "Not trusted", tone: item.trusted ? accent : .tronSlate),
                    subtext: item.displayPath, monoSubtext: true)) { projectDestination(item) }
            }
            TronListGroup([ProjectLifecycleAddAction.create], identifier: "\(identifierPrefix)-add-row") { _ in
                ProjectLifecycleSheetRow(content: projectLifecycleRow("Add Project", icon: "plus", accent: accent), destination: addDestination)
            }
            TronSettingsCaption("Trust allows a project's extensions and hooks to load. Trust changes always wait for your approval.")
        }
    }
}

@MainActor
struct ProjectLifecycleAddPage<CreateDestination: View>: View {
    var identifierPrefix = "project-lifecycle"
    @ViewBuilder let createDestination: () -> CreateDestination
    let chooseExisting: () -> Void

    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronPrimary }

    var body: some View {
        ProjectLifecyclePage("Add Project", identifier: "\(identifierPrefix)-add") {
            TronListGroup(ProjectLifecycleAddAction.allCases, hasLeading: true, identifier: "\(identifierPrefix)-add-choices") { item in
                switch item {
                case .create:
                    ProjectLifecycleSheetRow(content: projectLifecycleRow("Create Project", icon: "folder.badge.plus", subtitle: "New Git repository on your Mac", accent: accent), destination: createDestination)
                case .existing:
                    TronListButton(projectLifecycleRow("Choose Existing Folder", icon: "folder", subtitle: "Inspect a folder without changing its trust", accent: accent),
                        identifier: "\(identifierPrefix)-existing", action: chooseExisting)
                }
            }
            TronSettingsCaption("New projects start untrusted until you approve trust.")
        }
    }
}

@MainActor
struct ProjectLifecycleCreatePage: View {
    let workspace: String
    @Binding var name: String
    var identifierPrefix = "project-lifecycle"
    var footer: String?
    let requestCreate: () -> Void

    var body: some View {
        ProjectLifecyclePage("Create Project", identifier: "\(identifierPrefix)-create") {
            TronSettingsGroup("Name") {
                ProjectLifecycleNameField(name: $name, identifier: "\(identifierPrefix)-name")
                TronSettingsDivider()
                TronSettingsRow(icon: "folder", title: "Location", subtitle: "\(workspace)/\(name)", subtitleLineLimit: nil)
            }
            TronSettingsCaption("Use 1–64 letters, numbers, hyphens or underscores. Start with a letter or number.")
            ProjectLifecycleActionButton(title: "Create Project", icon: "plus", subtitle: "Review before the project is created and trusted", action: requestCreate)
            TronSettingsCaption("Approving creates a Git repository on main, untrusted until creation finishes, then trusted. Cancelling creates nothing.")
            if let footer { TronSettingsCaption(footer) }
        }
    }
}

@MainActor
struct ProjectLifecycleDetailPage: View {
    let project: ProjectLifecycleProject
    var identifierPrefix = "project-lifecycle"
    let identifier: String
    let requestTrust: () -> Void
    let requestUntrust: () -> Void

    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronPrimary }

    var body: some View {
        ProjectLifecyclePage(project.name, identifier: identifier) {
            TronSettingsGroup(nil) {
                TronSettingsRow(icon: project.trusted ? "checkmark.shield" : "shield.slash", title: project.trusted ? "Trusted" : "Not trusted",
                    subtitle: project.displayPath, subtitleLineLimit: nil)
            }
            if project.trusted {
                TronListGroup([ProjectLifecycleManageAction.untrust], hasLeading: true, identifier: "\(identifierPrefix)-manage-rows") { _ in
                    TronListButton(projectLifecycleRow("Untrust Project", icon: "shield.slash", subtitle: "Keep the folder; stop loading extensions and hooks", accent: accent),
                        identifier: "\(identifierPrefix)-untrust", action: requestUntrust)
                        .disabled(project.untrustUnavailableReason != nil)
                }
                if let reason = project.untrustUnavailableReason { TronSettingsCaption(reason) }
            } else {
                ProjectLifecycleActionButton(title: "Request Trust", icon: "checkmark.shield", subtitle: "Review before extensions and hooks can load", action: requestTrust)
                    .disabled(project.trustUnavailableReason != nil)
                if let reason = project.trustUnavailableReason { TronSettingsCaption(reason) }
            }
            TronSettingsCaption("Every trust or untrust request opens its exact review card. No action is approved automatically.")
        }
    }
}

private enum ProjectLifecycleAddAction: String, CaseIterable, Identifiable {
    case create, existing
    var id: String { rawValue }
}
private enum ProjectLifecycleManageAction: String, Identifiable {
    case untrust
    var id: String { rawValue }
}

@MainActor
private struct ProjectLifecyclePage<Content: View>: View {
    let title: String
    let identifier: String
    let content: Content
    init(_ title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.content = content()
    }
    var body: some View {
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) { content }
                .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private struct ProjectLifecycleSheetRow<Destination: View>: View {
    let content: TronListRowContent
    @ViewBuilder let destination: () -> Destination
    var body: some View {
        TronProgressiveSheetLink(accessibilityLabel: content.title, detents: .fixed([.medium, .large]), destination: destination) {
            TronListRow(content)
        }
    }
}

@MainActor
private struct ProjectLifecycleNameField: View {
    @Binding var name: String
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project name").font(TronTypography.settingsRowSubtext)
            TextField("Project name", text: $name)
                .font(TronTypography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityIdentifier(identifier)
        }.padding(14)
    }
}

@MainActor
private struct ProjectLifecycleActionButton: View {
    let title: String
    let icon: String
    let subtitle: String
    let action: () -> Void
    @Environment(\.tronSettingsVisualTheme) private var theme
    var body: some View {
        Button(action: action) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleLineLimit: nil, titleColor: theme?.accent ?? .tronPrimary)
        }.buttonStyle(.plain).tronGlassSurface(accent: .tronPrimarySurface, interactive: true)
    }
}

@MainActor
private func projectLifecycleRow(_ title: String, icon: String, subtitle: String? = nil, accent: Color) -> TronListRowContent {
    TronListRowContent(leading: .icon(icon, accent), title: title, subtext: subtitle)
}
