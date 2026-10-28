import SwiftUI
import TronMobileCore

/// Presentation-local advisory reads. The Gateway and the existing settings
/// receipt/approval owners retain every effect, including work accepted offscreen.
@MainActor
struct ProjectLifecycleView: View {
    enum Route: Hashable {
        case list, add, create, details(String), rename(String)
    }
    let route: Route
    var workspace = ""
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var presentationCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @PresentationState private var listing: ProjectLifecycleListing?
    @PresentationState private var project: ProjectLifecycleRow?
    @PresentationState private var error: String?
    @PresentationState private var name = ""
    @PresentationState private var github = false
    @PresentationState private var submitting = false
    @PresentationState private var generation = 0
    @PresentationState private var approval: SettingsApprovalSelection?
    @PresentationState private var choosingFolder = false
    @PresentationState private var chosenPath: String?
    @PresentationState private var selected: SelectedPath?

    private struct SelectedPath: Identifiable {
        let id: String
    }
    private struct ReadID: Hashable {
        let route: Route
        let identity: KnowledgePresentationIdentity
        let settings, trust, approvals, foreground: Int
    }

    var body: some View {
        Group {
            if let error {
                TronSettingsNotice(message: error, title: "Project status", retry: { Task { await load() } })
            } else { content }
        }
        .disabled(submitting)
        // The presenting sheet's theme carries through; only a standalone presentation falls back.
        .tronSettingsVisualTheme(inheriting: .tronPrimary)
        .tronManagedSheet(item: $approval, identity: { "settings.projects.\($0.id)" }) {
            SettingsApprovalSheet(selection: $0)
        }
        .tronManagedSheet(isPresented: $choosingFolder, identity: "settings.projects.existing", onDismiss: {
            if let chosenPath { selected = SelectedPath(id: chosenPath) }
            chosenPath = nil
        }) {
            WorkspaceBrowser { chosenPath = $0 }
        }
        .tronManagedSheet(item: $selected, identity: { "settings.projects.inspect.\($0.id)" }) { selection in
            NavigationStack {
                ProjectLifecycleView(route: .details(selection.id), workspace: workspace)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { selected = nil } label: { Image(systemName: "checkmark").tronToolbarAction() }
                                .accessibilityLabel("Done")
                        }
                    }
            }
            .tronTopBlur(.sheet).tronPresentation().tronSettingsLayout()
            .presentationDetents([.medium, .large])
        }
        .task(id: PresentationActivityTaskID(source: ReadID(route: route, identity: model.knowledgePresentationIdentity,
            settings: model.settingsInvalidationGeneration, trust: model.trustRevision,
            approvals: model.settingsApprovalsRevision, foreground: model.foregroundReconciliationGeneration),
            presentationActive: activity.allowsPresentationPublication)) {
            guard activity.allowsPresentationPublication else { return }
            await load()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in if !active { generation &+= 1 } }
        .onChange(of: model.selectedGatewayProfileID()) { _, _ in
            generation &+= 1; listing = nil; project = nil; chosenPath = nil; selected = nil; approval = nil
        }
        .onDisappear { generation &+= 1 }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .list:
            if let listing {
                ProjectLifecycleProjectsPage(projects: listing.projects.map { presentation($0, root: listing.workspace) }) { row in
                    ProjectLifecycleView(route: .details(row.path), workspace: listing.workspace)
                } addDestination: {
                    ProjectLifecycleView(route: .add, workspace: listing.workspace)
                }
            } else { TronLoadingState(label: "Loading projects…") }
        case .add:
            ProjectLifecycleAddPage {
                ProjectLifecycleView(route: .create, workspace: workspace)
            } chooseExisting: { choosingFolder = true }
        case .create:
            ProjectLifecycleCreatePage(workspace: "~/Workspace", name: $name, github: $github) {
                request(.create, sourceName: name)
            }
        case .details:
            if let project {
                ProjectLifecycleDetailPage(project: presentation(project, root: workspace), github: $github, identifier: "project-lifecycle-details") {
                    ProjectLifecycleView(route: .rename(project.path), workspace: workspace)
                } requestTrust: { request(.trust, sourceName: project.name) }
                  requestArchive: { request(.archive, sourceName: project.name) }
                  requestUntrust: { request(.untrust, sourceName: project.name) }
            } else { TronLoadingState(label: "Inspecting project…") }
        case .rename:
            if let project {
                ProjectLifecycleRenamePage(project: presentation(project, root: workspace), workspace: "~/Workspace", name: $name) {
                    request(.rename, sourceName: project.name, newName: name)
                }
            } else { TronLoadingState(label: "Inspecting project…") }
        }
    }

    private func presentation(_ row: ProjectLifecycleRow, root: String) -> ProjectLifecycleProject {
        // Display abbreviation never becomes an RPC path or mutation identity.
        let home = URL(fileURLWithPath: root).deletingLastPathComponent().path
        let display = row.path.hasPrefix(home + "/") ? "~" + row.path.dropFirst(home.count) : row.path
        return ProjectLifecycleProject(name: row.name, path: row.path, displayPath: display, trusted: row.trust?.effectiveDecision == true,
            archiveUnavailableReason: row.eligibility.archive.refusal, trustUnavailableReason: row.eligibility.trust.refusal,
            githubUnavailableReason: row.eligibility.github.refusal, renameUnavailableReason: row.eligibility.rename.refusal,
            untrustUnavailableReason: row.eligibility.untrust.refusal)
    }

    private func load() async {
        guard activity.allowsPresentationPublication, !Task.isCancelled else { return }
        generation &+= 1
        let ticket = generation, identity = model.knowledgePresentationIdentity
        func admits() -> Bool { ticket == generation && !Task.isCancelled && identity == model.knowledgePresentationIdentity }
        guard model.gatewayInfo?.capabilities.contains("projects.lifecycle.v1") == true else {
            error = "This Mac does not support native project lifecycle requests."; return
        }
        error = nil
        do {
            switch route {
            case .list:
                try await model.refreshSettingsSnapshot(for: SettingsTarget.global.gatewayTarget)
                guard admits() else { return }
                var page = try await model.settingsTrust.listProjects()
                guard admits() else { return }
                let listed = Set(page.projects.map(\.path))
                let saved = model.settingsSnapshot(for: SettingsTarget.global.gatewayTarget)?.resolution.keys
                    .filter { $0.key == TrustedProjectsSettingsView.key }.compactMap { $0.qualifiers?["project"] } ?? []
                let archive = URL(fileURLWithPath: page.workspace).appendingPathComponent(".archive").path
                for path in Set(saved).subtracting(listed).sorted() {
                    // Trust keeps deny tombstones after moves. They are not
                    // projects, and must not undo the listing owner's hidden
                    // archive namespace. Other saved unsupported folders remain.
                    guard path != archive, !path.hasPrefix(archive + "/") else { continue }
                    let row = try await model.settingsTrust.inspectProject(path: path)
                    guard admits() else { return }
                    guard row.eligibility.archive.code != "not_found" else { continue }
                    page.projects.append(row)
                }
                listing = page
            case .details(let path), .rename(let path):
                let row = try await model.settingsTrust.inspectProject(path: path)
                guard admits() else { return }
                project = row
                if case .rename = route, name.isEmpty { name = row.name }
            case .add, .create: break
            }
        } catch is CancellationError {
        } catch {
            guard admits() else { return }
            self.error = error.localizedDescription
        }
    }

    private func request(_ operation: ProjectLifecycleOperation, sourceName: String, newName: String? = nil) {
        guard !submitting, activity.allowsDataPublication else { return }
        submitting = true
        let identity = model.knowledgeDestinationIdentity
        // Settings events retire disposable reads, not this accepted mutation.
        // The existing surface owner fences its eventual presentation instead.
        func admitsPresentation() -> Bool {
            identity == model.knowledgeDestinationIdentity && PresentationPublicationPolicy.allows(
                ambient: activity, coordinator: presentationCoordinator, token: surfaceToken)
        }
        // This task is not the disposable read task. Its accepted command stays
        // with the canonical receipt executor even after this sheet disappears.
        Task { @MainActor in
            defer { submitting = false }
            do {
                let reference = try await model.settingsTrust.requestProject(operation, name: sourceName, newName: newName, github: github)
                guard admitsPresentation() else { return }
                approval = .request(reference)
            } catch {
                guard admitsPresentation() else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
