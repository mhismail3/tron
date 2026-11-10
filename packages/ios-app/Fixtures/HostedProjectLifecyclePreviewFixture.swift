#if HOSTED_TEST
import SwiftUI
import TronMobileCore

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

@MainActor
private struct HostedProjectLifecycleContent: View {
    let surface: String
    @PresentationState private var name = "field-notes"
    @PresentationState private var choosingFolder = false
    @PresentationState private var approval: HostedProjectApprovalPreview?

    private let example = ProjectLifecycleProject(name: "Example", path: "~/Workspace/Example", displayPath: "~/Workspace/Example", trusted: true)
    private let fieldNotes = ProjectLifecycleProject(name: "field-notes", path: "~/Workspace/field-notes", displayPath: "~/Workspace/field-notes", trusted: false)

    var body: some View {
        content
            .tronManagedSheet(item: $approval, identity: { "preview.project-lifecycle.\($0.rawValue)" }) { action in
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
            ProjectLifecycleCreatePage(workspace: "~/Workspace", name: $name,
                identifierPrefix: "project-preview", footer: "Design preview only — no project is created and no command is sent.") {
                approval = .trust
            }
        case "trusted", "untrusted", "busy":
            let item = surface == "untrusted" ? fieldNotes : ProjectLifecycleProject(name: example.name, path: example.path, displayPath: example.displayPath,
                trusted: true, untrustUnavailableReason: surface == "busy"
                    ? "Project has an active or pending Home worker" : nil)
            ProjectLifecycleDetailPage(project: item, identifierPrefix: "project-preview", identifier: "project-preview-\(surface)",
                requestTrust: { approval = .trust }, requestUntrust: { approval = .untrust })
        default:
            ProjectLifecycleProjectsPage(projects: [example, fieldNotes], identifierPrefix: "project-preview") { item in
                HostedProjectLifecycleContent(surface: item.trusted ? "trusted" : "untrusted")
            } addDestination: {
                HostedProjectLifecycleContent(surface: "add")
            }
        }
    }
}

enum HostedProjectApprovalPreview: String, CaseIterable, Identifiable {
    case trust, untrust
    var id: String { "preview-project-\(rawValue)" }

    init?(surface: String) {
        switch surface {
        case "trust-review": self = .trust
        case "untrust": self = .untrust
        default: return nil
        }
    }

    var review: ChangeReview {
        let source = "~/Workspace/\(self == .trust ? "field-notes" : "Example")"
        let destination: String
        switch self {
        case .trust: destination = "Trusted: project extensions and hooks load."
        case .untrust: destination = "Not trusted: the folder stays and project extensions and hooks stop loading."
        }
        let value: JSONValue = .object(["digest": .string("preview-digest-\(rawValue)"), "title": .string("\(rawValue.capitalized) project"),
            "requiresTap": .bool(true), "reason": .string("Synthetic visual review only. No project command is submitted."),
            "items": .array([.object(["label": .string("Project"), "before": .string(source), "after": .string(destination)])])])
        return try! value.decode(ChangeReview.self)
    }
}
#endif
