#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// #2023 visual proposal only. Synthetic projects; no lifecycle commands or decisions.
/// Production integration is deliberately deferred until the maintainer approves the captures.
@MainActor
struct HostedProjectLifecyclePreview: View {
    let surface: String
    @PresentationState private var presented = true
    @State private var name = "field-notes"
    @State private var github = false
    @State private var requestNotice = false

    var body: some View {
        Text("Project lifecycle · Design preview")
            .font(TronTypography.body)
            .tronManagedSheet(isPresented: $presented, identity: "preview.project-lifecycle") {
                NavigationStack {
                    content
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { presented = false } label: {
                                    Image(systemName: "checkmark").tronToolbarAction()
                                }.accessibilityLabel("Done")
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
            TronSettingsGroup("Projects") {
                link("Example", icon: "folder", subtitle: "Trusted · ~/Workspace/Example") {
                    project(trusted: true, busy: false)
                }
                TronSettingsDivider()
                link("field-notes", icon: "folder", subtitle: "Not trusted · ~/Workspace/field-notes") {
                    project(trusted: false, busy: false)
                }
            }
            link("Add Project", icon: "plus") { addProject }
                .tronGlassSurface(accent: .tronPrimarySurface, interactive: true)
            TronSettingsCaption("Trust allows a project's extensions and hooks to load. Lifecycle changes always wait for your approval.")
        }
    }

    private var addProject: some View {
        page("Add Project") {
            TronSettingsGroup(nil) {
                link("Create Project", icon: "folder.badge.plus", subtitle: "New Git repository on your Mac") { createProject }
                TronSettingsDivider()
                link("Choose Existing Folder", icon: "folder", subtitle: "Add a folder without granting trust") {
                    WorkspaceBrowser { _ in }
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
            action("Create Project", icon: "plus", subtitle: "Create locally, then review trust approval")
            TronSettingsCaption("The Gateway creates an untrusted Git repository on main. Trust and optional private GitHub creation need a separate approval tap. Denying leaves the local project untrusted.")
            previewNotice
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
                action("Request Trust", icon: "checkmark.shield", subtitle: "Review before extensions and hooks can load")
            }
            TronSettingsGroup("Manage Project") {
                link("Rename Project", icon: "pencil", subtitle: "Move the folder; GitHub is not renamed") { renameProject }
                TronSettingsDivider()
                Button { requestNotice = true } label: {
                    TronSettingsRow(icon: "archivebox", title: "Archive Project", subtitle: "Move to ~/Workspace/.archive; keep all files", subtitleLineLimit: nil)
                }.buttonStyle(.plain).disabled(busy)
                if trusted {
                    TronSettingsDivider()
                    Button { requestNotice = true } label: {
                        TronSettingsRow(icon: "shield.slash", title: "Untrust Project", subtitle: "Keep the folder; stop loading extensions and hooks", subtitleLineLimit: nil)
                    }.buttonStyle(.plain)
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
            previewNotice
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
            action("Request Rename", icon: "pencil", subtitle: "Review the exact move before approving")
            TronSettingsCaption("The folder moves only after approval. Trust is preserved after a successful move. GitHub repositories and historical session paths are not renamed.")
            previewNotice
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

    private var previewNotice: some View {
        Group {
            if requestNotice {
                TronSettingsCaption("Design preview only — no request sent. Production will open the canonical approval sheet with the Gateway's exact preview and approve/deny controls.")
            }
        }
    }

    private func action(_ title: String, icon: String, subtitle: String) -> some View {
        Button { requestNotice = true } label: {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleLineLimit: nil, titleColor: .tronPrimary)
        }.buttonStyle(.plain).tronGlassSurface(accent: .tronPrimarySurface, interactive: true)
    }

    private func link<Destination: View>(_ title: String, icon: String, subtitle: String? = nil,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, detents: .fixed([.medium, .large]), destination: destination) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, subtitleLineLimit: nil) {
                Image(systemName: "chevron.right").foregroundStyle(Color.tronPrimary)
            }
        }
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
#endif
