#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Synthetic tool-boundary data rendered by the production sheets and transcript chips.
struct HostedWorkerToolFixture: View {
    let surface: String
    @State private var showing = true

    var body: some View {
        Color.clear.tronManagedSheet(isPresented: $showing, identity: "worker-tool-review.\(surface)") {
            Group {
                if surface == "worker-tools" || surface == "worker-identities" {
                    let tools = surface == "worker-identities" ? Self.identityTools : Self.tools
                    ToolRunDetailSheet(run: ChatToolRunPresentation(tools: tools), tools: tools)
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
                                let tool = surface.hasPrefix("worker-home-read-") ? Self.homeRead(surface)
                                    : surface == "worker-report" ? Self.reportForReview : HostedSixSmallUIFixture.checkin(blocked: true)
                                ToolDetailSheet(tool: tool, density: .expanded)
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
                }
            }
            .tronTopBlur(.toolDetail).tronPresentation().tronSettingsLayout()
            .presentationDetents([.large]).presentationDragIndicator(.hidden)
        }
    }

    /// Same bounded file data, rendered through the old generic tool and the
    /// shared Pi read presentation. This is synthetic UI evidence, not live data.
    static func homeRead(_ surface: String) -> ChatToolPresentation {
        let before = surface == "worker-home-read-before"
        return tool(before ? "read_file" : "read", request: .object([
            "path": .string("/workspace/project/notes.txt"), "offset": .number(2), "limit": .number(3)
        ]), details: before ? .object(["status": .string("ok")]) : .object([:]),
        content: (before ? "/workspace/project/notes.txt lines 2–4 of 12\n" : "")
            + "line 2 of the file\nline 3 of the file\nline 4 of the file")
    }

    static var reportForReview: ChatToolPresentation {
        let args = ProcessInfo.processInfo.arguments
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
