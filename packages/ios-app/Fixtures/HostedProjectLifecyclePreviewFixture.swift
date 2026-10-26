#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// #2023 visual proposal only. Synthetic projects; no lifecycle commands or decisions.
/// List anatomy comes from TronList, and every drill-in is a managed sub-sheet.
@MainActor
struct HostedProjectLifecyclePreview: View {
    let surface: String
    @PresentationState private var presented = true
    var body: some View {
        Text("Project lifecycle · Design preview")
            .font(TronTypography.body)
            .tronManagedSheet(isPresented: $presented, identity: "preview.project-lifecycle") {
                Group {
                    if let action = HostedProjectApprovalPreview(surface: surface) {
                        SettingsApprovalSheet(selection: .request(SettingsApprovalReference(requestID: action.id, changeIDs: [])))
                    } else {
                        NavigationStack {
                            HostedProjectLifecycleContent(surface: surface)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button { presented = false } label: {
                                            Image(systemName: "checkmark").tronToolbarAction()
                                        }.accessibilityLabel("Done")
                                    }
                                }
                        }
                    }
                }
                .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
                .tronTopBlur(.sheet)
                .tronPresentation()
                .tronSettingsLayout()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
    }
}

/// Each presented page owns its own child sheets; a covered list never presents
/// an approval on behalf of the project sheet above it.
@MainActor
private struct HostedProjectLifecycleContent: View {
    let surface: String
    @PresentationState private var name = "field-notes"
    @PresentationState private var github = false
    @PresentationState private var choosingFolder = false
    @PresentationState private var approval: HostedProjectApprovalPreview?

    private struct Project: Identifiable {
        let name: String
        let trusted: Bool
        var id: String { name }
    }
    private enum ManageAction: String, Identifiable {
        case rename, archive, untrust
        var id: String { rawValue }
    }
    private enum AddAction: String, CaseIterable, Identifiable {
        case create, existing
        var id: String { rawValue }
    }

    var body: some View {
        content
            .tronManagedSheet(item: $approval, identity: { "preview.project-lifecycle.\($0.rawValue)" }) { action in
                approvalSheet(action)
            }
            .tronManagedSheet(isPresented: $choosingFolder, identity: "preview.project-lifecycle.existing") {
                // This shared browser owns its own sheet-local NavigationStack.
                WorkspaceBrowser { _ in choosingFolder = false }
            }
    }

    @ViewBuilder private var content: some View {
        switch surface {
        case "add": addProject
        case "create": createProject
        case "untrusted": project(trusted: false, busy: false)
        case "trusted": project(trusted: true, busy: false)
        case "busy": project(trusted: true, busy: true)
        case "rename": renameProject
        default: projects
        }
    }

    private var projects: some View {
        page("Trusted Projects") {
            TronSettingsGroup(nil) {
                SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "global",
                    presentation: .keys([TrustedProjectsSettingsView.policyKey]), detailedKeys: true)
            }
            TronListGroup(sections: [TronListSection(title: "Projects", rows: [
                Project(name: "Example", trusted: true), Project(name: "field-notes", trusted: false),
            ])], identifier: "project-preview-list-rows") { item in
                sheetRow(TronListRowContent(title: item.name,
                    status: TronListStatus(text: item.trusted ? "Trusted" : "Not trusted", tone: item.trusted ? .tronPrimary : .tronSlate),
                    subtext: "~/Workspace/\(item.name)", monoSubtext: true)) {
                    HostedProjectLifecycleContent(surface: item.trusted ? "trusted" : "untrusted")
                }
            }
            TronListGroup([AddAction.create], identifier: "project-preview-add-row") { _ in
                sheetRow(row("Add Project", icon: "plus")) { HostedProjectLifecycleContent(surface: "add") }
            }
            TronSettingsCaption("Trust allows a project's extensions and hooks to load. Lifecycle changes always wait for your approval.")
        }
    }

    private var addProject: some View {
        page("Add Project") {
            TronListGroup(AddAction.allCases, hasLeading: true, identifier: "project-preview-add-choices") { item in
                switch item {
                case .create:
                    sheetRow(row("Create Project", icon: "folder.badge.plus", subtitle: "New Git repository on your Mac")) {
                        HostedProjectLifecycleContent(surface: "create")
                    }
                case .existing:
                    TronListButton(row("Choose Existing Folder", icon: "folder", subtitle: "Inspect a folder without changing its trust"),
                        identifier: "project-preview-existing") { choosingFolder = true }
                }
            }
            TronSettingsCaption("New projects start untrusted. Nothing is pushed to GitHub.")
        }
    }

    private var createProject: some View {
        page("Create Project") {
            TronSettingsGroup("Name") {
                nameField
                TronSettingsDivider()
                TronSettingsRow(icon: "folder", title: "Location", subtitle: "~/Workspace/\(name)", subtitleLineLimit: nil)
            }
            TronSettingsCaption("Use 1–64 letters, numbers, hyphens or underscores. Start with a letter or number.")
            githubOption
            action("Create Project", icon: "plus", subtitle: "Create locally, then review trust approval", approval: .trust)
            TronSettingsCaption("The Gateway creates an untrusted Git repository on main. Trust and optional private GitHub creation need a separate approval tap. Denying leaves the local project untrusted.")
            TronSettingsCaption("Design preview only — no project is created and no command is sent.")
        }
    }

    private func project(trusted: Bool, busy: Bool) -> some View {
        page(trusted ? "Example" : "field-notes") {
            TronSettingsGroup(nil) {
                TronSettingsRow(icon: trusted ? "checkmark.shield" : "shield.slash", title: trusted ? "Trusted" : "Not trusted",
                    subtitle: "~/Workspace/\(trusted ? "Example" : "field-notes")", subtitleLineLimit: nil)
            }
            if !trusted {
                githubOption
                action("Request Trust", icon: "checkmark.shield", subtitle: "Review before extensions and hooks can load", approval: .trust)
            }
            TronListGroup(sections: [TronListSection(title: "Manage Project", rows: trusted
                ? [ManageAction.rename, .archive, .untrust] : [ManageAction.rename, .archive])],
                hasLeading: true, identifier: "project-preview-manage-rows") { item in
                switch item {
                case .rename:
                    sheetRow(row("Rename Project", icon: "pencil", subtitle: "Move the folder; GitHub is not renamed")) {
                        HostedProjectLifecycleContent(surface: "rename")
                    }
                case .archive:
                    TronListButton(row("Archive Project", icon: "archivebox", subtitle: "Move to ~/Workspace/.archive; keep all files"),
                        identifier: "project-preview-archive") { approval = .archive }
                        .disabled(busy)
                case .untrust:
                    TronListButton(row("Untrust Project", icon: "shield.slash", subtitle: "Keep the folder; stop loading extensions and hooks"),
                        identifier: "project-preview-untrust") { approval = .untrust }
                }
            }
            if busy {
                TronSettingsGroup(nil) {
                    TronSettingsRow(icon: "exclamationmark.triangle", title: "Archive unavailable",
                        subtitle: "An active task is using this project. Wait for it to finish or stop it before archiving.",
                        subtitleLineLimit: nil, accent: .tronWarning)
                }
            }
            TronSettingsCaption("Every trust, rename, archive or untrust request opens the existing approval review. No action is approved automatically.")
            TronSettingsCaption("Archives are recoverable on your Mac at ~/Workspace/.archive/<name>-<id>. Project sessions must be closed before moving; start new sessions at the new location.")
        }
    }

    private var renameProject: some View {
        page("Rename Project") {
            TronSettingsGroup(nil) {
                TronSettingsRow(icon: "folder", title: "Current location", subtitle: "~/Workspace/Example", subtitleLineLimit: nil)
                TronSettingsDivider()
                nameField
                TronSettingsDivider()
                TronSettingsRow(icon: "folder", title: "New location", subtitle: "~/Workspace/\(name)", subtitleLineLimit: nil)
            }
            action("Request Rename", icon: "pencil", subtitle: "Review the exact move before approving", approval: .rename)
            TronSettingsCaption("The folder moves only after approval. Trust is preserved after a successful move. GitHub repositories and historical session paths are not renamed.")
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project name").font(TronTypography.settingsRowSubtext)
            TextField("Project name", text: $name)
                .font(TronTypography.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("project-preview-name")
        }.padding(14)
    }

    private var githubOption: some View {
        TronSettingsGroup(nil) {
            TronSettingsRow(icon: "arrow.triangle.branch", title: "Private GitHub Repository",
                subtitle: "Create a private repository and origin after approval. Uses the Mac's GitHub sign-in; never pushes.", subtitleLineLimit: nil) {
                Toggle("Private GitHub Repository", isOn: $github).labelsHidden()
            }
        }
    }

    private func action(_ title: String, icon: String, subtitle: String, approval action: HostedProjectApprovalPreview) -> some View {
        Button { approval = action } label: {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleLineLimit: nil, titleColor: .tronPrimary)
        }.buttonStyle(.plain).tronGlassSurface(accent: .tronPrimarySurface, interactive: true)
    }

    private func row(_ title: String, icon: String, subtitle: String? = nil) -> TronListRowContent {
        TronListRowContent(leading: .icon(icon, .tronPrimary), title: title, subtext: subtitle)
    }

    private func sheetRow<Destination: View>(_ content: TronListRowContent,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: content.title, detents: .fixed([.medium, .large]), destination: destination) {
            TronListRow(content)
        }
    }

    private func approvalSheet(_ action: HostedProjectApprovalPreview) -> some View {
        // Reuse the actual canonical review, not an extra confirmation or a push destination.
        SettingsApprovalSheet(selection: .request(SettingsApprovalReference(requestID: action.id, changeIDs: [])))
    }

    private func page<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 20, hidesLoneHeading: true) { content() }
                .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .accessibilityIdentifier("project-preview-\(surface)")
    }
}

/// Socket-served synthetic action previews for the production approval sheet.
/// Decisions are refused by the fixture socket: this gallery cannot apply anything.
enum HostedProjectApprovalPreview: String, CaseIterable, Identifiable {
    case trust, rename, archive, untrust
    var id: String { "preview-project-\(rawValue)" }

    init?(surface: String) {
        switch surface {
        case "trust-review": self = .trust
        case "rename-review": self = .rename
        case "archive": self = .archive
        case "untrust": self = .untrust
        default: return nil
        }
    }

    static var requests: [JSONValue] {
        allCases.map { action in
            let source = "~/Workspace/\(action == .trust ? "field-notes" : "Example")"
            var items: [JSONValue] = [.object(["label": .string("Project"), "value": .string(source)])]
            if action == .archive || action == .rename {
                items.append(.object(["label": .string("Destination"), "value": .string(action == .archive
                    ? "~/Workspace/.archive/Example-00000000-0000-4000-8000-000000000023" : "~/Workspace/field-notes")]))
            }
            let effect: String
            switch action {
            case .trust: effect = "Allow project extensions and hooks to load. No GitHub repository is created in this sample."
            case .rename: effect = "Move the folder and preserve trust after success. GitHub and historical sessions are not renamed."
            case .archive: effect = "Keep all files in a recoverable archive and remove trust. No hard delete."
            case .untrust: effect = "Keep the folder and stop loading project extensions and hooks."
            }
            items.append(.object(["label": .string("Effect"), "value": .string(effect)]))
            return .object(["requestId": .string(action.id), "digest": .string("preview-digest-\(action.rawValue)"),
                "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
                "expiresAt": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))),
                "actor": .object(["kind": .string("ui"), "id": .string("fixture-device")]),
                "target": .object(["kind": .string("global")]), "requester": .string("iPhone design preview"),
                "reason": .string("Synthetic visual review only. No project command was submitted; decisions are disabled by the fixture."),
                "changes": .array([]), "action": .object(["subject": .string("project.lifecycle"),
                    "title": .string("\(action.rawValue.capitalized) project"), "items": .array(items)])])
        }
    }
}
#endif
