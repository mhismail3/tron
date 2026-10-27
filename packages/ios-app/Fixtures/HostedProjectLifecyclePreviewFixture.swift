#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Synthetic driver of the production-owned presentation. No lifecycle commands
/// or decisions: only the real native owner may supply those effects.
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

/// Fixtures alone supply sample paths, draft values and simulated effects. Each
/// presented page owns its own child sheets, including the canonical review.
@MainActor
private struct HostedProjectLifecycleContent: View {
    let surface: String
    @PresentationState private var name = "field-notes"
    @PresentationState private var github = false
    @PresentationState private var choosingFolder = false
    @PresentationState private var approval: HostedProjectApprovalPreview?

    private let example = ProjectLifecycleProject(name: "Example", path: "~/Workspace/Example", displayPath: "~/Workspace/Example", trusted: true)
    private let fieldNotes = ProjectLifecycleProject(name: "field-notes", path: "~/Workspace/field-notes", displayPath: "~/Workspace/field-notes", trusted: false)

    var body: some View {
        content
            .tronManagedSheet(item: $approval, identity: { "preview.project-lifecycle.\($0.rawValue)" }) { action in
                SettingsApprovalSheet(selection: .request(SettingsApprovalReference(requestID: action.id, changeIDs: [])))
            }
            .tronManagedSheet(isPresented: $choosingFolder, identity: "preview.project-lifecycle.existing") {
                WorkspaceBrowser { _ in choosingFolder = false }
            }
    }

    @ViewBuilder private var content: some View {
        switch surface {
        case "add":
            ProjectLifecycleAddPage(identifierPrefix: "project-preview") {
                HostedProjectLifecycleContent(surface: "create")
            } chooseExisting: { choosingFolder = true }
        case "create":
            ProjectLifecycleCreatePage(workspace: "~/Workspace", name: $name, github: $github,
                identifierPrefix: "project-preview", footer: "Design preview only — no project is created and no command is sent.") {
                approval = .trust
            }
        case "trusted", "untrusted", "busy":
            let item = surface == "untrusted" ? fieldNotes : ProjectLifecycleProject(name: example.name, path: example.path, displayPath: example.displayPath,
                trusted: true, archiveUnavailableReason: surface == "busy"
                    ? "An active task is using this project. Wait for it to finish or stop it before archiving." : nil)
            ProjectLifecycleDetailPage(project: item, github: $github, identifierPrefix: "project-preview",
                identifier: "project-preview-\(surface)") {
                HostedProjectLifecycleContent(surface: "rename")
            } requestTrust: { approval = .trust }
              requestArchive: { approval = .archive }
              requestUntrust: { approval = .untrust }
        case "rename":
            ProjectLifecycleRenamePage(project: example, workspace: "~/Workspace", name: $name, identifierPrefix: "project-preview") {
                approval = .rename
            }
        default:
            ProjectLifecycleProjectsPage(projects: [example, fieldNotes], identifierPrefix: "project-preview") { item in
                HostedProjectLifecycleContent(surface: item.trusted ? "trusted" : "untrusted")
            } addDestination: {
                HostedProjectLifecycleContent(surface: "add")
            }
        }
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
