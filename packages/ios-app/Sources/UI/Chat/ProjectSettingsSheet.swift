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

struct ProjectSettingsLink: View {
    /// A settings row in Manage Session; a setup card among New Session's choices.
    enum Style { case row, setupCard }
    static let setupCardCaption = "Read-only repository overrides in .pi."
    let cwd: String
    let profileID: String
    /// The row's glyph matches the rows around it.
    var accent: Color = .tronEmerald
    var style: Style = .row

    var body: some View {
        TronProgressiveSheetLink(
            accessibilityLabel: "Project Settings",
            identity: "project.settings.\(profileID).\(cwd)",
            accent: .tronEmerald,
            destination: { ProjectSettingsContent(cwd: cwd, profileID: profileID) }
        ) {
            switch style {
            case .row:
                TronSettingsRow(icon: "folder.badge.gearshape", title: "Project Settings",
                                subtitle: URL(fileURLWithPath: cwd).lastPathComponent, accent: accent)
            case .setupCard:
                TronSetupCardLabel(icon: "folder.badge.gearshape", title: "Project Settings",
                                   value: URL(fileURLWithPath: cwd).lastPathComponent,
                                   caption: Self.setupCardCaption, accent: accent)
            }
        }
        // The link's label is its title; the card's value and subtext stay readable.
        .accessibilityValue(style == .setupCard ? "\(URL(fileURLWithPath: cwd).lastPathComponent), \(Self.setupCardCaption)" : "")
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
                                .tronToolbarAction(accent: .tronEmerald)
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

struct ProjectSettingsContent: View {
    let cwd: String
    let profileID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var trust: ProjectTrustSummary?
    @PresentationState private var git: GitInspection?
    @PresentationState private var error: String?
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.selectedGatewayProfileID() != profileID {
                    TronPlaceholderState(title: "Project on another Mac",
                        detail: "Use this project's server before inspecting its repository overrides.",
                        icon: "desktopcomputer", actionTitle: "Use This Server") {
                        guard let profile = model.profiles.profiles.first(where: { $0.id == profileID }) else { return }
                        Task { await model.switchGateway(profile) }
                    }
                } else {
                    // Every header row is present from the first frame, so loading
                    // fills values in place instead of inserting rows (no flicker).
                    TronSettingsGroup("Project", detail: cwd, accent: .tronEmerald) {
                        TronSettingsRow(icon: trust?.stateIcon ?? "shield", title: trust?.stateTitle ?? "Trust",
                                        subtitle: trust?.stateDetail ?? " ", subtitleColor: .tronTextSecondary)
                        TronSettingsDivider()
                        TronSettingsRow(icon: "arrow.triangle.branch", title: "Workspace",
                                        subtitle: git.map { !$0.isRepository ? "Not a Git repository"
                                            : $0.isDirty ? "Uncommitted changes" : "No uncommitted changes" } ?? " ",
                                        subtitleColor: .tronTextSecondary) {
                            TronDynamicValue(text: git.map { $0.isRepository ? ($0.branch ?? "Detached HEAD") : "—" } ?? "")
                        }
                    }
                    if let error {
                        TronSettingsNotice(message: error, retry: { reload &+= 1 })
                    }
                    TronSettingsCaption("View-only repository configuration. Only actual overrides are listed; inherited Mac and built-in values are not repository settings. Edit .pi files in the repository, not in the app.")
                    let target = SettingsTarget.project(cwd: cwd).gatewayTarget
                    if let snapshot = model.settingsSnapshot(for: target) {
                        if snapshot.resolution.keys.contains(where: SettingsKeySelection.overrides("project").includes) {
                            SettingsConfigurationGroups(target: target, selection: .overrides("project"))
                        } else {
                            TronPlaceholderState(title: "No repository overrides", detail: "Sessions inherit Mac defaults where permitted.", icon: "folder.badge.gearshape")
                        }
                    } else { TronSheetLoadingState(label: "Loading repository overrides…") }
                    TronGlassCard {
                        SettingsChangesLink(scope: .project(cwd), subtitle: "One audit history · Repository changes")
                    }
                }
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project Settings")
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { generation &+= 1 }
        }
        .onDisappear { generation &+= 1 }
        .task(id: PresentationActivityTaskID(source: model.settingsFreshness,
                                             presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication, model.selectedGatewayProfileID() == profileID else { return }
            try? await model.refreshSettingsSnapshot(for: SettingsTarget.project(cwd: cwd).gatewayTarget)
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
            let inspectedGit = try await model.gatewayDiagnostics.inspectGit(path: cwd)
            guard current() else { return }
            git = inspectedGit
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard current() else { return }
            self.error = error.localizedDescription
        }
    }
}
