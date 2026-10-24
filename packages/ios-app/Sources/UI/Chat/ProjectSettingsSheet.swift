import SwiftUI
import TronMobileCore

/// One project surface for Manage Session, the dashboard and pre-chat setup.
/// The caller supplies its exact workspace and Gateway; this view never changes
/// cwd, discovers a different root, or infers settings state from Git history.
struct ProjectSettingsRoute: Identifiable {
    let cwd: String
    let profileID: String
    var id: String { "\(profileID)|\(cwd)" }
}

/// New Session's setup card for the chosen workspace's Project Settings.
struct ProjectSettingsLink: View {
    static let setupCardCaption = "Read-only repository overrides in .pi."
    let cwd: String
    let profileID: String
    var accent: Color = .tronPrimary

    var body: some View {
        TronProgressiveSheetLink(
            accessibilityLabel: "Project Settings",
            identity: "project.settings.\(profileID).\(cwd)",
            accent: .tronPrimary,
            destination: { ProjectSettingsContent(cwd: cwd, profileID: profileID) }
        ) {
            TronSetupCardLabel(icon: "folder.badge.gearshape", title: "Project Settings",
                               value: URL(fileURLWithPath: cwd).lastPathComponent,
                               caption: Self.setupCardCaption, accent: accent)
        }
        // The link's label is its title; the card's value and subtext stay readable.
        .accessibilityValue("\(URL(fileURLWithPath: cwd).lastPathComponent), \(Self.setupCardCaption)")
        .accessibilityIdentifier("project-settings-link")
    }
}

struct ProjectSettingsSheet: View {
    let route: ProjectSettingsRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProjectSettingsContent(cwd: route.cwd, profileID: route.profileID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark").font(TronTypography.buttonSM)
                                .tronToolbarAction(accent: .tronPrimary)
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .tronPresentation()
        .tronSettingsLayout()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

/// The standalone Project Settings page (New Session, the dashboard).
struct ProjectSettingsContent: View {
    let cwd: String
    let profileID: String

    var body: some View {
        ScrollView {
            ProjectSettingsSections(cwd: cwd, profileID: profileID, showsWorkspace: true)
                .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project Settings")
    }
}

/// The project's trust, workspace and read-only repository values. Project
/// Settings shows them alone; Session Settings shows them under its own groups,
/// where Manage Session's Workspace row already names the branch.
struct ProjectSettingsSections: View {
    let cwd: String
    let profileID: String
    let showsWorkspace: Bool
    /// Session Settings supplies its rows to the one group that also owns trust.
    /// Standalone Project Settings keeps its existing project/workspace layout.
    var sessionSettings: AnyView? = nil
    /// More Settings follows Project Trust in the same Session settings card.
    var sessionSettingsAfterTrust: AnyView? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var trust: ProjectTrustSummary?
    @PresentationState private var git: GitInspection?
    @PresentationState private var error: String?
    @PresentationState private var settingsError: String?
    @PresentationState private var generation = 0
    @PresentationState private var reload = 0

    private struct ReadID: Hashable {
        let cwd: String
        let profileID: String
        let identity: KnowledgePresentationIdentity
        let trustRevision: Int
        let settingsRevision: Int
        let foreground: Int
        let reload: Int
    }

    private var readID: ReadID {
        ReadID(cwd: cwd, profileID: profileID, identity: model.knowledgePresentationIdentity,
               trustRevision: model.trustRevision, settingsRevision: model.settingsInvalidationGeneration,
               foreground: model.foregroundReconciliationGeneration, reload: reload)
    }

    var body: some View {
        TronSettingsSections(alignment: .leading, spacing: 18) {
            if model.selectedGatewayProfileID() != profileID {
                TronPlaceholderState(title: "Project on another Mac",
                    detail: "Use this project's server before inspecting its repository overrides.",
                    icon: "desktopcomputer", actionTitle: "Use This Server") {
                    guard let profile = model.profiles.profiles.first(where: { $0.id == profileID }) else { return }
                    Task { await model.switchGateway(profile) }
                }
            } else {
                // The rows are fixed once the overrides arrive (the sheet's pulse
                // hides them until then); trust and Git fill values in place.
                TronSettingsGroup(sessionSettings == nil ? "Project" : "Settings",
                                  detail: sessionSettings == nil ? cwd : nil, accent: .tronPrimary) {
                    if let sessionSettings {
                        sessionSettings
                        TronSettingsDivider()
                    }
                    // The row opens the project's one trust editor; its own look is unchanged.
                    TronProgressiveSheetLink(accessibilityLabel: "Project Trust", identity: "project.settings.trust.\(profileID).\(cwd)",
                                             destination: { TrustSettingsView(target: TrustTarget(cwd: cwd)) }) {
                        TronSettingsRow(icon: trust?.stateIcon ?? "shield", title: sessionSettings == nil ? (trust?.stateTitle ?? "Trust") : "Project Trust",
                                        subtitle: trust?.stateDetail ?? " ", subtitleColor: .tronTextSecondary) {
                            if sessionSettings != nil { TronDynamicValue(text: trust?.stateTitle ?? "") }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityValue(trust?.stateTitle ?? "")
                    .accessibilityIdentifier("project-settings-trust")
                    if let sessionSettingsAfterTrust {
                        TronSettingsDivider()
                        sessionSettingsAfterTrust
                    }
                    if showsWorkspace {
                        TronSettingsDivider()
                        TronSettingsRow(icon: "arrow.triangle.branch", title: "Workspace",
                                        subtitle: git.map { !$0.isRepository ? "Not a Git repository"
                                            : $0.isDirty ? "Uncommitted changes" : "No uncommitted changes" } ?? " ",
                                        subtitleColor: .tronTextSecondary) {
                            TronDynamicValue(text: git.map { $0.isRepository ? ($0.branch ?? "Detached HEAD") : "—" } ?? "")
                        }
                    }
                }
                if let error {
                    TronSettingsNotice(message: error, retry: { reload &+= 1 })
                }
                let target = SettingsTarget.project(cwd: cwd).gatewayTarget
                if let snapshot = model.settingsSnapshot(for: target) {
                    SettingsProjectNotices(resolution: snapshot.resolution)
                    if snapshot.resolution.keys.contains(where: SettingsKeySelection.projectValues.includes) {
                        SettingsProjectGroups(target: target)
                    } else {
                        TronSettingsGroup("Repository Overrides") {
                            TronSettingsRow(icon: "folder.badge.gearshape", title: "No repository overrides",
                                            subtitle: "Sessions inherit Global settings.", subtitleColor: .tronTextSecondary)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("project-settings-no-overrides")
                    }
                    TronSettingsCaption("Read-only Project settings. Only allowed repository values are listed. Ask an agent to update them in the repo.").containerValue(\.tronSettingsSection, false)
                } else if let settingsError {
                    TronPlaceholderState(title: "Repository overrides unavailable", detail: settingsError,
                                         icon: "folder.badge.gearshape", actionTitle: "Retry") { reload &+= 1 }
                } else { TronSheetLoadingState(label: "Loading repository overrides…") }
            }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { generation &+= 1 }
        }
        .onDisappear { generation &+= 1 }
        .task(id: PresentationActivityTaskID(source: [model.settingsFreshness.invalidation, model.settingsFreshness.foreground, reload],
                                             presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication, model.selectedGatewayProfileID() == profileID else { return }
            do {
                try await model.refreshSettingsSnapshot(for: SettingsTarget.project(cwd: cwd).gatewayTarget)
                guard !Task.isCancelled else { return }
                settingsError = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, presentationActivity.allowsPresentationPublication else { return }
                settingsError = error.localizedDescription
            }
        }
        .task(id: PresentationActivityTaskID(source: readID,
                                           presentationActive: presentationActivity.allowsPresentationPublication)) {
            await load()
        }
    }

    private func load() async {
        guard presentationActivity.allowsPresentationPublication,
              model.selectedGatewayProfileID() == profileID, let target = TrustTarget(cwd: cwd) else { return }
        let request = readID
        let activity = presentationActivity
        generation &+= 1
        let ticket = generation
        func current() -> Bool {
            !Task.isCancelled && ticket == generation && request == readID
                && activity == presentationActivity && activity.allowsPresentationPublication
        }
        do {
            let inspection = try await model.inspectTrust(target: target)
            guard current() else { return }
            trust = ProjectTrustSummary(inspection)
            if showsWorkspace {
                let inspectedGit = try await model.gatewayDiagnostics.inspectGit(path: cwd)
                guard current() else { return }
                git = inspectedGit
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard current() else { return }
            self.error = error.localizedDescription
        }
    }
}
