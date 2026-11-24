#if HOSTED_TEST
import SwiftUI
import TronMobileCore

struct HostedWorkerToolFixture: View {
    let surface: String
    @State private var showing = true

    @State private var thinking = false

    var body: some View {
        if surface == "worker-reopen" {
            VStack(spacing: 24) {
                ToolCard(data: Self.write)
                Button("Open Thinking") { thinking = true }
                    .tronManagedSheet(isPresented: $thinking, identity: "worker-reopen.thinking") {
                        ThinkingTraceDetailSheet(inline: MarkdownPresentation.Inline(source: Self.thought), identity: "worker-reopen", streaming: false)
                    }
            }
        } else {
            review
        }
    }

    static let write = tool("write", request: .object(["path": .string("/work/tron/notes.md"), "content": .string("# Notes\n\nThe sheet fits its content.")]),
                            content: "Successfully wrote 38 bytes to /work/tron/notes.md")

    private var review: some View {
        Color.clear.tronManagedSheet(isPresented: $showing, identity: "worker-tool-review.\(surface)") {
            if surface == "worker-identities" || surface == "worker-tools-short" {
                let tools = surface == "worker-identities" ? Self.identityTools : Array(Self.identityTools.prefix(2))
                ToolRunDetailSheet(run: ChatToolRunPresentation(tools: tools), tools: tools).tronSettingsLayout()
            } else if surface.hasPrefix("worker-thinking") {
                ThinkingTraceDetailSheet(inline: MarkdownPresentation.Inline(source: surface == "worker-thinking-long"
                    ? Array(repeating: Self.thought, count: 12).joined(separator: "\n\n") : Self.thought),
                    identity: surface, streaming: false)
            } else {
                NavigationStack {
                    Group {
                        if surface == "worker-chips" {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    Text("Worker progress").font(TronTypography.headline)
                                    Text("The shared tool sheets are ready for review.").font(TronTypography.bodySM)
                                    ForEach(Self.tools.prefix(2)) { tool in ToolCard(data: tool) }
                                    ToolActivityChip(run: ChatToolRunPresentation(tools: Self.tools), action: {})
                                }.padding(16)
                            }.tronNavigationTitle("Transcript")
                        } else {
                            let tool = surface == "worker-report" ? Self.reportForReview : HostedSixSmallUIFixture.checkin(blocked: true)
                            ToolDetailSheet(tool: tool)
                                .toolbar { ToolbarItem(placement: .principal) { ToolDetailNavigationTitle(tool: tool) } }
                        }
                    }
                    .tronToolDetailNavigationChrome()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { showing = false } label: { Image(systemName: "checkmark").tronToolbarAction() }.accessibilityLabel("Done")
                        }
                    }
                }
                .tronTopBlur(.toolDetail).tronPresentation().tronSettingsLayout()
            }
        }
    }

    static let thought = "The user wants the sheet to fit its content. I should measure the scroll content, not the sheet, so the height cannot feed back into itself."

    static var reportForReview: ChatToolPresentation {
        let args = HostedLaunch.arguments
        guard let index = args.firstIndex(of: "-worker-report-outcome"), args.indices.contains(index + 1) else { return report }
        var request = report.request!.objectValue!
        request["outcome"] = .string(args[index + 1])
        return tool("report", request: .object(request), details: report.details!, content: report.content)
    }

    static let identityTools = [report, tool("checkin", request: HostedSixSmallUIFixture.checkin(blocked: true).request!, details: HostedSixSmallUIFixture.checkin(blocked: true).details!)] + ["subagent", "settings", "knowledge", "mcp__wordcraft__preview_document", "extension_preview_document", "previewDocument"].map { tool($0) }

    static let report = tool("report", request: .object([
        "resultId": .string("worker-result"), "outcome": .string("final"),
        "text": .string("## Tool sheets ready\n\nReport and check-in now use **shared components** and the selected primary theme.\n\nReview [issue #1955](https://example.org/issues/1955) before landing."),
        "evidence": .array([.string("**Visual proof:** light and dark simulator captures."), .string("Commit `abc1234` · focused UI verification pending approval.")])
    ]), details: .object(["entryId": .string("5dee638b")]), content: "Task report sealed.")

    static let tools: [ChatToolPresentation] = [report, HostedSixSmallUIFixture.checkin(blocked: true)] + ["ask_user", "notify", "zoom", "date", "memory_search", "delegate", "task", "profile", "web_search", "session_read", "read_file", "extension_preview_document"].map { tool($0) }

    static func tool(_ name: String, request: JSONValue = .object([:]), details: JSONValue = .object([:]), content: String = "Completed") -> ChatToolPresentation {
        ChatToolPresentation(id: "worker-review-\(name)", title: name, toolName: name, subtitle: "Completed", request: request, response: details, content: content, fallbackContent: nil, details: details, error: false, startedAt: "2026-10-24T09:00:00Z", completedAt: "2026-10-24T09:00:01Z", durationMs: 1000, lastProgressAt: nil, progressSequence: nil)
    }
}
#endif
