import SwiftUI
import TronMobileCore

/// Disposable presentation data. The lifecycle read owner must supply canonical
/// paths, effective trust and refusal reasons; these views never infer eligibility.
struct ProjectLifecycleProject: Identifiable {
    let name: String
    let path: String
    let displayPath: String
    let trusted: Bool
    var archiveUnavailableReason: String?
    var trustUnavailableReason: String?
    var githubUnavailableReason: String?
    var renameUnavailableReason: String?
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

    var body: some View {
        ProjectLifecyclePage("Trusted Projects", identifier: "\(identifierPrefix)-list") {
            TronSettingsGroup(nil) {
                SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "global",
                    presentation: .keys([TrustedProjectsSettingsView.policyKey]), detailedKeys: true)
            }
            TronListGroup(sections: [TronListSection(title: "Projects", rows: projects)],
                identifier: "\(identifierPrefix)-list-rows") { item in
                ProjectLifecycleSheetRow(content: TronListRowContent(title: item.name,
                    status: TronListStatus(text: item.trusted ? "Trusted" : "Not trusted", tone: item.trusted ? .tronPrimary : .tronSlate),
                    subtext: item.displayPath, monoSubtext: true)) { projectDestination(item) }
            }
            TronListGroup([ProjectLifecycleAddAction.create], identifier: "\(identifierPrefix)-add-row") { _ in
                ProjectLifecycleSheetRow(content: projectLifecycleRow("Add Project", icon: "plus"), destination: addDestination)
            }
            TronSettingsCaption("Trust allows a project's extensions and hooks to load. Lifecycle changes always wait for your approval.")
        }
    }
}

@MainActor
struct ProjectLifecycleAddPage<CreateDestination: View>: View {
    var identifierPrefix = "project-lifecycle"
    @ViewBuilder let createDestination: () -> CreateDestination
    let chooseExisting: () -> Void

    var body: some View {
        ProjectLifecyclePage("Add Project", identifier: "\(identifierPrefix)-add") {
            TronListGroup(ProjectLifecycleAddAction.allCases, hasLeading: true, identifier: "\(identifierPrefix)-add-choices") { item in
                switch item {
                case .create:
                    ProjectLifecycleSheetRow(content: projectLifecycleRow("Create Project", icon: "folder.badge.plus", subtitle: "New Git repository on your Mac"), destination: createDestination)
                case .existing:
                    TronListButton(projectLifecycleRow("Choose Existing Folder", icon: "folder", subtitle: "Inspect a folder without changing its trust"),
                        identifier: "\(identifierPrefix)-existing", action: chooseExisting)
                }
            }
            TronSettingsCaption("New projects start untrusted. Nothing is pushed to GitHub.")
        }
    }
}

@MainActor
struct ProjectLifecycleCreatePage: View {
    let workspace: String
    @Binding var name: String
    @Binding var github: Bool
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
            ProjectLifecycleGitHubOption(github: $github)
            ProjectLifecycleActionButton(title: "Create Project", icon: "plus", subtitle: "Create locally, then review trust approval", action: requestCreate)
            TronSettingsCaption("The Gateway creates an untrusted Git repository on main. Trust and optional private GitHub creation need a separate approval tap. Denying leaves the local project untrusted.")
            if let footer { TronSettingsCaption(footer) }
        }
    }
}

@MainActor
struct ProjectLifecycleDetailPage<RenameDestination: View>: View {
    let project: ProjectLifecycleProject
    @Binding var github: Bool
    var identifierPrefix = "project-lifecycle"
    let identifier: String
    @ViewBuilder let renameDestination: () -> RenameDestination
    let requestTrust: () -> Void
    let requestArchive: () -> Void
    let requestUntrust: () -> Void

    var body: some View {
        ProjectLifecyclePage(project.name, identifier: identifier) {
            TronSettingsGroup(nil) {
                TronSettingsRow(icon: project.trusted ? "checkmark.shield" : "shield.slash", title: project.trusted ? "Trusted" : "Not trusted",
                    subtitle: project.displayPath, subtitleLineLimit: nil)
            }
            if !project.trusted {
                ProjectLifecycleGitHubOption(github: $github)
                    .disabled(project.githubUnavailableReason != nil)
                if let reason = project.githubUnavailableReason { TronSettingsCaption(reason) }
                ProjectLifecycleActionButton(title: "Request Trust", icon: "checkmark.shield", subtitle: "Review before extensions and hooks can load", action: requestTrust)
                    .disabled(project.trustUnavailableReason != nil)
                if let reason = project.trustUnavailableReason { TronSettingsCaption(reason) }
            }
            TronListGroup(sections: [TronListSection(title: "Manage Project", rows: project.trusted
                ? [ProjectLifecycleManageAction.rename, .archive, .untrust] : [ProjectLifecycleManageAction.rename, .archive])],
                hasLeading: true, identifier: "\(identifierPrefix)-manage-rows") { item in
                switch item {
                case .rename:
                    ProjectLifecycleSheetRow(content: projectLifecycleRow("Rename Project", icon: "pencil", subtitle: "Move the folder; GitHub is not renamed"), destination: renameDestination)
                        .disabled(project.renameUnavailableReason != nil)
                case .archive:
                    TronListButton(projectLifecycleRow("Archive Project", icon: "archivebox", subtitle: "Move to ~/Workspace/.archive; keep all files"),
                        identifier: "\(identifierPrefix)-archive", action: requestArchive)
                        .disabled(project.archiveUnavailableReason != nil)
                case .untrust:
                    TronListButton(projectLifecycleRow("Untrust Project", icon: "shield.slash", subtitle: "Keep the folder; stop loading extensions and hooks"),
                        identifier: "\(identifierPrefix)-untrust", action: requestUntrust)
                        .disabled(project.untrustUnavailableReason != nil)
                }
            }
            if let reason = project.renameUnavailableReason { TronSettingsCaption(reason) }
            if project.trusted, let reason = project.untrustUnavailableReason { TronSettingsCaption(reason) }
            if let reason = project.archiveUnavailableReason {
                TronSettingsGroup(nil) {
                    TronSettingsRow(icon: "exclamationmark.triangle", title: "Archive unavailable", subtitle: reason,
                        subtitleLineLimit: nil, accent: .tronWarning)
                }
            }
            TronSettingsCaption("Every trust, rename, archive or untrust request opens the existing approval review. No action is approved automatically.")
            TronSettingsCaption("Archives are recoverable on your Mac at ~/Workspace/.archive/<name>-<id>. Project sessions must be closed before moving; start new sessions at the new location.")
        }
    }
}

@MainActor
struct ProjectLifecycleRenamePage: View {
    let project: ProjectLifecycleProject
    let workspace: String
    @Binding var name: String
    var identifierPrefix = "project-lifecycle"
    let requestRename: () -> Void

    var body: some View {
        ProjectLifecyclePage("Rename Project", identifier: "\(identifierPrefix)-rename") {
            TronSettingsGroup(nil) {
                TronSettingsRow(icon: "folder", title: "Current location", subtitle: project.displayPath, subtitleLineLimit: nil)
                TronSettingsDivider()
                ProjectLifecycleNameField(name: $name, identifier: "\(identifierPrefix)-name")
                TronSettingsDivider()
                TronSettingsRow(icon: "folder", title: "New location", subtitle: "\(workspace)/\(name)", subtitleLineLimit: nil)
            }
            ProjectLifecycleActionButton(title: "Request Rename", icon: "pencil", subtitle: "Review the exact move before approving", action: requestRename)
            TronSettingsCaption("The folder moves only after approval. Trust is preserved after a successful move. GitHub repositories and historical session paths are not renamed.")
        }
    }
}

private enum ProjectLifecycleAddAction: String, CaseIterable, Identifiable {
    case create, existing
    var id: String { rawValue }
}
private enum ProjectLifecycleManageAction: String, Identifiable {
    case rename, archive, untrust
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
private struct ProjectLifecycleGitHubOption: View {
    @Binding var github: Bool
    var body: some View {
        TronSettingsGroup(nil) {
            TronSettingsRow(icon: "arrow.triangle.branch", title: "Private GitHub Repository",
                subtitle: "Create a private repository and origin after approval. Uses the Mac's GitHub sign-in; never pushes.", subtitleLineLimit: nil) {
                Toggle("Private GitHub Repository", isOn: $github).labelsHidden()
            }
        }
    }
}

@MainActor
private struct ProjectLifecycleActionButton: View {
    let title: String
    let icon: String
    let subtitle: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleLineLimit: nil, titleColor: .tronPrimary)
        }.buttonStyle(.plain).tronGlassSurface(accent: .tronPrimarySurface, interactive: true)
    }
}

@MainActor
private func projectLifecycleRow(_ title: String, icon: String, subtitle: String? = nil) -> TronListRowContent {
    TronListRowContent(leading: .icon(icon, .tronPrimary), title: title, subtext: subtitle)
}
