#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Capture-only entry points into production views with synthetic boundary data.
struct HostedSixSmallUIFixture: View {
    let surface: String
    @Environment(AppModel.self) private var model
    @State private var showing = true
    @State private var activity = PresentationActivityCoordinator()
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: ModelRef? = ModelRef(provider: "opencode-go", id: "deepseek-v4.1-flash")

    var body: some View {
        Color.clear
            .tronManagedSheet(isPresented: $showing, identity: "six-ui.\(surface)") {
                Group {
                    if surface == "workspace" {
                        destination
                    } else {
                        NavigationStack {
                    destination
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { showing = false } label: { Image(systemName: "checkmark").tronToolbarAction() }
                                    .accessibilityLabel("Done")
                            }
                        }
                }
                    }
                }
                .tronTopBlur(.sheet)
                .tronPresentation()
                .tronSettingsLayout()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
            .background {
                if surface == "toast" {
                    InAppNoticeWindowInstaller(model: model, colorScheme: colorScheme, presentationActivity: activity)
                        .frame(width: 0, height: 0).allowsHitTesting(false)
                }
            }
            .task {
                if surface == "toast" {
                    model.postNotice("iOS rebuild and install accepted. This app will relaunch after installation.",
                                     role: .progress, lifetime: .automatic(.seconds(120)), priority: .low)
                }
            }
    }

    @ViewBuilder private var destination: some View {
        switch surface {
        case "home":
            SessionSettingsView(sessionID: "fixture-chat", ownedLayers: ["session"], homeProfileID: "settings-renderer-fixture")
                .tronNavigationTitle("Home Settings")
        case "session":
            SessionSettingsView(sessionID: "fixture-chat", ownedLayers: ["session"], projectCWD: "/fixture/project")
                .tronNavigationTitle("Session Settings")
        case "models":
            ModelPicker(selection: $selection, models: Self.models)
                .tronNavigationTitle("Models")
        case "workspace":
            WorkspaceInspectorSheet(sessionID: "fixture-chat")
        case "checkin", "checkin-blocked":
            ToolDetailSheet(tool: Self.checkin(blocked: surface == "checkin-blocked"), density: .expanded)
                .tronNavigationTitle("Checkin")
        default:
            Text("Simulator preview · synthetic values")
                .font(TronTypography.settingsRowSubtext)
                .tronNavigationTitle("Notifications")
        }
    }

    static let models: [ModelSummary] = [
        ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash", 0.15, 0.60),
        ("deepseek-v4-pro", "DeepSeek V4 Pro", 0.30, 1.20),
        ("kimi-k2.7-code", "Kimi K2.7 Code", 0.40, 1.60)
    ].map { id, name, input, output in
        try! JSONDecoder.gateway.decode(ModelSummary.self, from: JSONSerialization.data(withJSONObject: [
            "provider": "opencode-go", "id": id, "name": name, "reasoning": true, "input": ["text"],
            "contextWindow": 1000000, "maxTokens": 32768, "available": true,
            "cost": ["input": input, "output": output, "cacheRead": 0, "cacheWrite": 0], "releaseDate": "2026-09-01"
        ]))
    }

    static func checkin(blocked: Bool) -> ChatToolPresentation {
        let request: JSONValue = .object([
            "step": .string("Landed with explicit validation deferral"),
            "done": .string("Prepared the six UI changes and captured light and dark simulator previews."),
            "next": .string("Review the previews, then run focused UI regressions after approval."),
            "needsAttention": .bool(blocked),
            "blocker": blocked ? .string("Visual approval is needed before testing and landing.") : .null
        ])
        var checkin = request.objectValue!
        checkin.merge(["id": .string("checkin-preview"), "taskId": .string("six-ui"), "sessionId": .string("worker"),
                       "operationId": .string("preview"), "at": .string("2026-10-24T09:00:00Z"),
                       "attention": .string(blocked ? "requested" : "none")]) { _, next in next }
        let details = JSONValue.object(["checkin": .object(checkin)])
        return ChatToolPresentation(id: "six-ui-checkin", title: "checkin", toolName: "checkin", subtitle: "Completed",
                                    request: request, response: details,
                                    content: "Check-in saved. Attention: \(blocked ? "requested" : "none"). Continue working.",
                                    fallbackContent: nil, details: details, error: false,
                                    startedAt: "2026-10-24T09:00:00Z", completedAt: "2026-10-24T09:00:01Z", durationMs: 1000,
                                    lastProgressAt: nil, progressSequence: nil)
    }
}
#endif
