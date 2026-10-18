#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Visual review data only. All destinations below are the production views.
struct HostedToolSheetsPolishFixture: View {
    @State private var showing = false
    @State private var routes = ChatTranscriptSheetRouteOwner()
    @Environment(\.dismiss) private var dismiss
    private var scenario: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-polish-scenario"), args.indices.contains(index + 1) else { return "ask" }
        return args[index + 1]
    }
    static let brief = """
    Fix: attaching photos must keep Send unavailable until every selected photo is ready.

    Preserve the existing composer, keyboard and transcript identity. A completed upload must not re-enable Send while another upload remains in progress.

    ## Implementation
    Trace the owning attachment coordinator and use the accepted upload lifecycle. Avoid an extra cache or polling timer. Keep errors recoverable and retain the user's selected files.

    ## Validation
    Capture light and dark simulator evidence. Exercise mixed photos, cancel during preparation, retry after a failed upload, and send after all attachments are ready. Do not install on a physical device or change the Stable Gateway.

    ## Delivery
    Commit checkpoints on the isolated branch. Report the exact evidence and residual uncertainty. Wait for visual approval before behavioral regression runs or merging.
    """
    static let report = (1...30).map { index in
        "## Gateway check \(index)\n\nThe session retained its authoritative transcript after reconnect. Accepted prompts were not replayed, and the selected worker kept the same session identity. The report is read-only context, not a new instruction.\n\n- Connection ownership remained explicit.\n- No production transition was performed.\n- Further device verification remains with the maintainer."
    }.joined(separator: "\n\n")

    var body: some View {
        VStack(spacing: 24) {
            Text("Transcript presentation review").font(TronTypography.headline)
            if scenario == "prompt" || scenario == "short-prompt" {
                ScrollView {
                    ChatUserPromptContent(text: scenario == "prompt" ? Self.brief : "Please inspect the selected photos and keep the current layout.")
                        .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { TronBackdrop().ignoresSafeArea() }
        .environment(\.chatTranscriptSheetRoutes, routes)
        .modifier(ChatTranscriptSheetHost(routes: routes))
        .tronManagedSheet(isPresented: $showing, identity: "hosted.polish.\(scenario)") { destination }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-polish-dark") ? .dark : .light)
        .tronPresentation()
        .task { showing = scenario != "prompt" && scenario != "short-prompt" }
    }

    @ViewBuilder private var destination: some View {
        if scenario == "context-long" || scenario == "context-short" {
            InboundContextDetailsSheet(item: Self.context(text: scenario == "context-long" ? Self.report : "Gateway checks completed. The session resumed without replaying the prompt. No production changes were made."))
        } else {
            let tool = Self.tool(scenario)
            NavigationStack {
                ToolDetailSheet(tool: tool, density: .expanded)
                    .tronToolDetailNavigationChrome()
                    .toolbar {
                        ToolbarItem(placement: .principal) { ToolDetailNavigationTitle(tool: tool) }
                        ToolbarItem(placement: .confirmationAction) {
                            Button { showing = false } label: {
                                Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: ToolDetailNavigationTitle.accent(for: tool))
                            }.accessibilityLabel("Done")
                        }
                    }
            }
            .tronTopBlur(.toolDetail)
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .tronPresentation()
        }
    }

    static func context(text: String) -> TranscriptItem {
        let object: [String: Any] = ["id": "review-context", "parentId": NSNull(), "timestamp": "2026-10-18T02:00:00Z", "kind": "customMessage", "customType": "worker-report", "content": [["id": "report-text", "ordinal": 0, "type": "text", "text": text]]]
        return try! JSONDecoder.gateway.decode(TranscriptItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func tool(_ scenario: String) -> ChatToolPresentation {
        let name: String
        let request: [String: Any]
        let details: [String: Any]
        switch scenario {
        case "delegate":
            name = "delegate"
            request = ["taskId": "photo-readiness", "title": "Photo readiness: preserve composer state", "target": "/workspace/project", "intent": brief,
                       "model": ["provider": "openai", "id": "gpt-6.1-sol"], "thinking": "high", "reason": "iOS UI work needing careful ownership and presentation judgment."]
            details = ["sessionId": "worker-session", "operationId": "worker-operation",
                       "worker": ["model": "openai/gpt-6.1-sol", "thinking": "high", "modelSource": "explicit: iOS UI work needing careful ownership and presentation judgment.", "thinkingSource": "explicit: iOS UI work needing careful ownership and presentation judgment."],
                       "subagentModels": [["model": "anthropic/claude-haiku-5-5", "available": false, "reason": "Weekly usage 97%"], ["model": "openai/gpt-6-luna", "available": true], ["model": "opencode-go/deepseek-v4.1-flash", "available": false, "reason": "Monthly usage 100%"]]]
        case "search":
            name = "session_search"
            request = ["query": "photo upload composer readiness"]
            details = ["status": "ok", "query": "photo upload composer readiness", "coverage": "partial", "ranking": "localSemantic", "hits": [
                ["sessionId": "session-one", "entryId": "entry-one", "title": "Photo attachments and Send readiness", "role": "assistant", "updatedAt": "2026-10-18T02:20:00Z", "snippet": "The attachment coordinator owns preparation. Send becomes available only when every selected photo is ready; retry retains the selected files."],
                ["sessionId": "session-two", "entryId": "entry-two", "title": "Preserve the composer during reconnect", "role": "user", "updatedAt": "2026-10-17T14:00:00Z", "snippet": "Keep the keyboard, draft and attachment previews in place while the authoritative session reconnects."]]]
        default:
            name = "ask_user"
            request = [:]
            details = ["title": "Transcript presentation", "cancelled": false, "questions": [["question": "Which improvements should ship together?", "options": [["label": "Tool sheet clarity", "description": "Readable results with technical details still reachable."], ["label": "Compact prompt previews", "description": "Bound long briefs without losing the full content."], ["label": "Keep the current layout"]], "multiSelect": true, "allowOther": false]], "answers": ["Which improvements should ship together?": ["selected": ["Tool sheet clarity", "Compact prompt previews"]]]]
        }
        let args = try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: request))
        let result = try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: details))
        // No live extensionOrigin: this is the canonical reloaded-call shape.
        return ChatToolPresentation(id: "review-\(name)", title: name, toolName: name, subtitle: "Completed", request: args,
                                    response: result, content: "Completed", fallbackContent: nil, details: result,
                                    error: false, startedAt: "2026-10-18T02:00:00Z", completedAt: "2026-10-18T02:04:06Z", durationMs: 246000,
                                    lastProgressAt: nil, progressSequence: nil)
    }
}
#endif
