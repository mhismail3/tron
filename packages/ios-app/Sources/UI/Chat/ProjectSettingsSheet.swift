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
    let cwd: String
    let profileID: String

    var body: some View {
        TronProgressiveSheetLink(
            accessibilityLabel: "Project settings",
            identity: "project.settings.\(profileID).\(cwd)",
            accent: .tronEmerald,
            destination: { ProjectSettingsContent(cwd: cwd, profileID: profileID) }
        ) {
            TronSettingsRow(icon: "folder.badge.gearshape", title: "Project settings",
                            subtitle: URL(fileURLWithPath: cwd).lastPathComponent,
                            accent: .tronEmerald)
        }
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
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .tronPresentation()
        .tronSettingsLayout()
        .presentationDragIndicator(.hidden)
    }
}

struct ProjectSettingsContent: View {
    let cwd: String
    let profileID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var trust: ProjectTrustSummary?
    @State private var git: GitInspection?
    @State private var error: String?
    @State private var generation = 0
    @State private var reload = 0

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
                        detail: "Use this project's server before reading or editing its settings.",
                        icon: "desktopcomputer", actionTitle: "Use This Server") {
                        guard let profile = model.profiles.profiles.first(where: { $0.id == profileID }) else { return }
                        Task { await model.switchGateway(profile) }
                    }
                } else {
                    TronSettingsGroup("Project", detail: cwd, accent: .tronEmerald) {
                        if let trust {
                            TronSettingsRow(icon: trust.stateIcon, title: trust.stateTitle, subtitle: trust.stateDetail)
                        }
                        if let git {
                            TronSettingsDivider()
                            TronValueRow(icon: "arrow.triangle.branch", title: "Workspace",
                                         value: git.isRepository ? (git.branch ?? "Detached HEAD") : "No repository")
                            if git.isDirty {
                                TronSettingsCaption("The workspace has uncommitted changes.")
                            }
                        }
                        TronSettingsDivider()
                        TronProgressiveSheetLink(accessibilityLabel: "Review trust", accent: .tronAmber,
                            destination: { TrustSettingsView(target: TrustTarget(cwd: cwd)) }) {
                            TronSettingsRow(icon: "checkmark.shield", title: "Review trust", accent: .tronAmber)
                        }
                    }
                    if let error {
                        TronSettingsNotice(message: error, retry: { reload &+= 1 })
                    }
                    SettingsRendererView(target: .object(["kind": .string("project"), "cwd": .string(cwd)]),
                                         writeLayer: "project", embedded: true, projectCWD: cwd)
                    TronSettingsCaption("Project values live in this workspace's .pi files. Changes are staged when possible; Tron never commits them.")
                }
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project settings")
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { generation &+= 1 }
        }
        .onDisappear { generation &+= 1 }
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
