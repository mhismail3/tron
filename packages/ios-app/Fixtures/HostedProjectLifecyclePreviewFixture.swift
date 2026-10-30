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
                        ChangeReviewSheet(review: action.review, approve: {}, cancel: { presented = false })
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
                // Design preview: Approve sends nothing; only the real owner confirms.
                ChangeReviewSheet(review: action.review, approve: {}, cancel: { approval = nil })
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

/// Synthetic exact reviews for the production review sheet. This gallery sends
/// no command, so its Approve cannot apply anything.
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

    var review: ChangeReview {
        let source = "~/Workspace/\(self == .trust ? "field-notes" : "Example")"
        let destination: String
        switch self {
        case .trust: destination = "Trusted: project extensions and hooks load. No GitHub repository is created in this sample."
        case .rename: destination = "~/Workspace/field-notes, trust preserved. GitHub and historical sessions are not renamed."
        case .archive: destination = "~/Workspace/.archive/Example-00000000-0000-4000-8000-000000000023, trust removed. No hard delete."
        case .untrust: destination = "Not trusted: the folder stays and project extensions and hooks stop loading."
        }
        let value: JSONValue = .object(["digest": .string("preview-digest-\(rawValue)"), "title": .string("\(rawValue.capitalized) project"),
            "requiresTap": .bool(true), "reason": .string("Synthetic visual review only. No project command is submitted."),
            "items": .array([.object(["label": .string("Project"), "before": .string(source), "after": .string(destination)])])])
        return try! value.decode(ChangeReview.self)
    }
}
#endif
