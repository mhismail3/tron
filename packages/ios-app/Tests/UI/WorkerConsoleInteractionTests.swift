import Foundation
import Testing
@testable import TronMobile

struct WorkerConsoleInteractionTests {
    @Test("Worker summaries turn protocol previews into readable user-facing text")
    func readableWorkerSummaryPresentation() {
        let request = #"{"budget":"high","question":"Compare the reporting across six sources.","depth":"deep"}"#
        #expect(
            WorkerRunGraphPresentation.requestSummary(request)
                == "Compare the reporting across six sources."
        )
        #expect(
            WorkerRunGraphPresentation.requestSummary(
                #"{"question":"Explain the durable run without showing JSON.","other":"truncated…"#
            ) == "Explain the durable run without showing JSON."
        )
        #expect(
            WorkerRunGraphPresentation.requestSummary(#"{"budget":"high","depth":"deep"}"#)
                == "Structured worker request"
        )

        let result = WorkerRunGraphPresentation.resultPresentation(
            "research.report.v1 · partial · The reviewed evidence supports a bounded conclusion."
        )
        #expect(result.status == "Partial")
        #expect(result.summary == "The reviewed evidence supports a bounded conclusion.")
    }

    @Test("Worker result fields use bounded JSON-pointer navigation")
    func workerResultFieldPresentation() throws {
        let reference = WorkerResultReferenceDTO(
            kind: "worker_result_reference",
            invocationId: "invocation",
            workerId: "worker",
            workerVersion: "version",
            outputSchemaSha256: "schema",
            contentSha256: "content",
            sizeBytes: 120,
            preview: "worker.result.v1 · complete · Finished",
            message: "Read selectively"
        )
        let chunk = WorkerResultChunkDTO(
            kind: "worker_result_chunk",
            reference: reference,
            pointer: "",
            value: AnyCodable([
                "summary": "Readable result",
                "path/to~value": true,
            ]),
            children: [],
            offset: 0,
            returned: 2,
            total: 2,
            nextOffset: nil,
            truncated: false
        )

        let fields = WorkerResultInspectorPresentation.fields(in: chunk)
        #expect(fields.first?.label == "Summary")
        #expect(
            fields.first(where: { $0.label == "Path/to~value" })?.pointer
                == "/path~1to~0value"
        )
        #expect(
            WorkerResultInspectorPresentation.isEmptyCollection(AnyCodable([String: Any]()))
        )
        #expect(
            WorkerResultInspectorPresentation.primitiveText(AnyCodable("Exact text"))
                == "Exact text"
        )
    }

    @Test("Run actions follow server status and foreground-background mode")
    func durableRunActionPolicy() {
        #expect(WorkerRunGraphPresentation.canDetach(status: "running", mode: "foreground"))
        #expect(!WorkerRunGraphPresentation.canDetach(status: "running", mode: "background"))
        #expect(WorkerRunGraphPresentation.canAwait(status: "running", mode: "background"))
        #expect(!WorkerRunGraphPresentation.canAwait(status: "completed", mode: "background"))
        #expect(WorkerRunGraphPresentation.canCancel(status: "queued"))
        #expect(!WorkerRunGraphPresentation.canCancel(status: "completed"))
        #expect(WorkerRunGraphPresentation.canRetry(status: "failed"))
        #expect(!WorkerRunGraphPresentation.canRetry(status: "cancelled"))
        #expect(WorkerRunGraphPresentation.canInspectResult(status: "completed"))
        #expect(!WorkerRunGraphPresentation.canInspectResult(status: "running"))
    }

    @Test("Only unresolved or active run details refresh after global invalidation")
    func durableRunInvalidationPolicy() {
        #expect(WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(status: nil))
        #expect(WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(status: "queued"))
        #expect(WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(status: "running"))
        #expect(!WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(status: "completed"))
        #expect(!WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(status: "failed"))
        #expect(!WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(status: "cancelled"))
    }

    @Test("Worker UI consumes structured graph stages and never joins raw event names")
    func durableRunPresentationUsesStructuredTruth() throws {
        let root = iosAppRoot()
        let graphComponents = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/WorkerRunGraphComponents.swift"
            ),
            encoding: .utf8
        )
        let graphController = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/WorkerToolRunGraphView.swift"
            ),
            encoding: .utf8
        )
        let graph = graphComponents + graphController
        let tool = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/Tools/ToolInvocationViews.swift"
            ),
            encoding: .utf8
        )
        let context = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/Chat/Sheets/SessionContextSheet.swift"
            ),
            encoding: .utf8
        )
        let resultInspector = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/WorkerResultInspectorSheet.swift"
            ),
            encoding: .utf8
        )

        #expect(graph.contains("WorkerRunGraphSummaryView"))
        #expect(graph.contains("WorkerRunCausalTreeView"))
        #expect(graph.contains("WorkerRunTimelineView"))
        #expect(graph.contains("entry.summary"))
        #expect(graph.contains("filter { !$0.technical }"))
        #expect(graph.contains("WorkerRunDetailLinksView"))
        #expect(graph.contains("WorkerRunTreeSheet"))
        #expect(graph.contains("WorkerRunTimelineSheet"))
        #expect(tool.contains("WorkerToolRunGraphView("))
        #expect(graph.contains(".workerRunProjectionInvalidated"))
        #expect(graph.contains("WorkerRunGraphPresentation.shouldRefreshAfterInvalidation"))
        #expect(graph.contains("Open full result"))
        #expect(!graph.contains("Inspect result"))
        #expect(graph.contains("WorkerResultInspectorSheet("))
        #expect(context.contains(".workerRunProjectionInvalidated"))
        #expect(!graph.contains("Started Filesystem"))
        #expect(!graph.contains("Finished Filesystem"))
        #expect(!graph.contains("joined(separator: \"\")"))
        #expect(!graphComponents.contains(#"Image(systemName: "arrow.up.right.square")"#))
        #expect(!resultInspector.contains(#"Image(systemName: "arrow.up.right.square")"#))
    }

    @Test("Worker run transcript exists only for a real child agent session")
    func workerRunTranscriptResolution() {
        #expect(
            WorkerRunTranscriptDestination.resolve(agentSessionId: "child-session")
                == .workerSession("child-session")
        )
        #expect(
            WorkerRunTranscriptDestination.resolve(agentSessionId: nil) == nil
        )
        #expect(
            WorkerRunTranscriptDestination.resolve(agentSessionId: "  ") == nil
        )
        #expect(
            WorkerRunTranscriptDestination.workerSession("child-session").title
                == "Worker Session"
        )
        #expect(
            WorkerRunTranscriptDestination.workerSession("child-session").accessibilityLabel
                == "Open worker session"
        )
    }

    @Test("Engine containers do not use trailing navigation chevrons")
    func engineContainersOmitTrailingChevrons() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let files = try FileManager.default.contentsOfDirectory(
            at: workerRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("chevron.right"),
                "\(file.lastPathComponent) must keep Engine containers free of trailing chevrons"
            )
        }
    }

    @Test("Unbounded worker detail uses sheets instead of inline disclosure")
    func unboundedWorkerDetailUsesSheets() throws {
        let root = iosAppRoot()
        let workerRoot = root.appendingPathComponent("Sources/UI/WorkerConsole")
        let files = try FileManager.default.contentsOfDirectory(
            at: workerRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("DisclosureGroup"),
                "\(file.lastPathComponent) must route unbounded detail to a sheet"
            )
        }

        let detail = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("WorkerJSONDetailSheet(title: \"Input Schema\""))
        #expect(components.contains("WorkerRunDetailSheet("))
        #expect(components.contains("WorkerJSONDetailSheet("))

        let resultInspector = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerResultInspectorSheet.swift"),
            encoding: .utf8
        )
        #expect(resultInspector.contains("struct WorkerResultInspectorSheet"))
        #expect(resultInspector.contains("repository.workerResult("))
        #expect(resultInspector.contains("chunk.children"))
        #expect(resultInspector.contains("WorkerResultTechnicalSheet"))
        #expect(resultInspector.contains("Open raw JSON"))
        #expect(resultInspector.contains("Result fields"))
        #expect(!resultInspector.contains(#"title: chunk.truncated ? "Result page" : "Result value""#))
        #expect(!resultInspector.contains("assembledResult"))
        let runDetail = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )
        #expect(runDetail.contains("WorkerResultInspectorSheet("))
        #expect(runDetail.contains("WorkerRunTechnicalDetailsSheet"))
        #expect(runDetail.contains("Legacy Worker Result"))
        #expect(!runDetail.contains("Inspect typed result"))
        #expect(!runDetail.contains("Run result projection"))
        #expect(!runDetail.contains("showOutput"))

        let codeBlockSource = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        #expect(codeBlockSource.contains(".fixedSize(horizontal: true, vertical: true)"))
    }

    @Test("Worker tabs and execution actions share liquid glass components")
    func workerControlsUseSharedLiquidGlass() throws {
        let root = iosAppRoot()
        let tabs = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronSegmentedControl.swift"),
            encoding: .utf8
        )
        let selectionStyle = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronGlassSelectionButtonStyle.swift"),
            encoding: .utf8
        )
        let action = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronPrimaryActionButton.swift"),
            encoding: .utf8
        )
        let workerDetail = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let delegation = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/DelegationSheet.swift"),
            encoding: .utf8
        )

        #expect(tabs.contains("GlassEffectContainer"))
        #expect(tabs.contains("TronGlassSelectionButtonStyle("))
        #expect(selectionStyle.contains(".glassEffect("))
        #expect(action.contains(".glassEffect("))
        #expect(workerDetail.contains("TronPrimaryActionButton("))
        #expect(delegation.contains("TronPrimaryActionButton("))
        #expect(!workerDetail.contains(".background(Color.tronEmerald"))
        #expect(!delegation.contains(".background(Color.tronPurple"))
    }

    @Test("Engine summary owns availability without a redundant Overview tab")
    func engineSummaryReplacesOverviewTab() throws {
        let root = iosAppRoot()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/WorkerConsoleViews.swift"),
            encoding: .utf8
        )
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/EngineDashboardViews.swift"),
            encoding: .utf8
        )

        #expect(!shell.contains("case overview = \"Overview\""))
        #expect(shell.contains("selectedSection: EngineDashboardSection = .workers"))
        let workersCase = try #require(shell.range(of: "case workers = \"Workers\""))
        let coreCase = try #require(shell.range(of: "case core = \"Core\""))
        #expect(workersCase.lowerBound < coreCase.lowerBound)
        #expect(shell.contains("engineHookSummary"))
        #expect(!shell.contains("overviewContent"))
        #expect(!dashboard.contains("struct EngineSurfaceCard"))
    }

    @Test("Worker sessions stay read only and inside dashboard sheets")
    func workerSessionsUseReadOnlySheets() throws {
        let root = iosAppRoot()
        let details = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
            encoding: .utf8
        )
        let chatHelpers = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/ChatView+Helpers.swift"),
            encoding: .utf8
        )
        let messageList = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/ChatView+MessageList.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/SessionSidebar.swift"),
            encoding: .utf8
        )
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/ContentView.swift"),
            encoding: .utf8
        )

        #expect(details.contains("WorkerAuditSessionSheet"))
        #expect(details.contains("presentationMode: .workerAudit"))
        #expect(details.contains("readOnlyTitle: title"))
        #expect(chat.contains("reconstructReadOnlyTranscript"))
        #expect(chat.contains("if presentationMode == .interactiveSession"))
        #expect(chat.contains("if presentationMode == .workerAudit"))
        #expect(chat.contains("content.tronScreenBackground()"))
        #expect(chatHelpers.contains("if presentationMode == .workerAudit"))
        #expect(chatHelpers.contains("[INIT] Worker audit loaded with"))
        #expect(chatHelpers.contains("bottom-anchored messages"))
        #expect(!chatHelpers.contains("positionScrollAtTop()"))
        #expect(messageList.contains("presentationMode == .workerAudit ? .bottom : .top"))
        #expect(messageList.contains("for: .initialOffset"))
        #expect(messageList.contains("for: .alignment"))
        #expect(!sidebar.contains("openWorkerAuditSession"))
        #expect(!content.contains("openWorkerAuditSession"))
    }

    @Test("Activity separates execution history from delivery audit")
    func activityUsesRunsAttentionAndExplicitAudit() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let shell = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleViews.swift"),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let audit = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )

        #expect(shell.contains("title: \"Worker runs\""))
        #expect(shell.contains("title: \"Attention\""))
        #expect(shell.contains("label: \"Unhealthy\""))
        #expect(shell.contains("Text(\"Open delivery audit\")"))
        #expect(detail.contains("private var attention: some View"))
        #expect(detail.contains("private var inboxAudit: some View"))
        #expect(!shell.contains("title: \"Durable inbox\""))
        #expect(!detail.contains("title: \"Durable inbox\""))
        #expect(audit.contains("struct WorkerInboxAuditSheet"))
        #expect(audit.contains("attentionOnly: false"))
    }

    @Test("Run cards use compact trailing metadata while delegated tasks retain one leading edge")
    func workerActivityCardsUseDeliberateTextAlignment() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        let delegation = try String(
            contentsOf: workerRoot.appendingPathComponent("DelegationSheet.swift"),
            encoding: .utf8
        )
        let workerRunCard = try sourceSlice(
            components,
            from: "struct WorkerRunCard: View",
            through: "struct WorkerInboxCard: View"
        )
        let delegationRunRow = try sourceSlice(
            delegation,
            from: "private struct DelegationRunRow: View",
            through: "func delegationStatusColor"
        )

        #expect(!delegationRunRow.contains("Spacer"))
        #expect(workerRunCard.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(workerRunCard.contains("VStack(alignment: .trailing"))
        #expect(workerRunCard.contains(".multilineTextAlignment(.trailing)"))
        #expect(workerRunCard.contains("WorkerConsolePresentation.compactRunIdentifier"))
        #expect(delegationRunRow.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    @Test("Worker experience summaries separate current attention from retained history")
    func workerExperienceSummariesUseCurrentAttention() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let delegation = try String(
            contentsOf: workerRoot.appendingPathComponent("DelegationSheet.swift"),
            encoding: .utf8
        )
        let research = try String(
            contentsOf: workerRoot.appendingPathComponent("ResearchSuiteSheet.swift"),
            encoding: .utf8
        )

        #expect(delegation.contains("metric(viewModel.currentAttentionCount, \"Attention\")"))
        #expect(research.contains("summaryMetric(viewModel.currentAttentionCount, \"Attention\")"))
        #expect(research.contains("Unavailable Report History"))
        #expect(!research.contains("older report"))
    }

    private func sourceSlice(
        _ source: String,
        from start: String,
        through end: String
    ) throws -> Substring {
        let lowerBound = try #require(source.range(of: start)?.lowerBound)
        let upperBound = try #require(
            source.range(of: end, range: lowerBound..<source.endIndex)?.lowerBound
        )
        return source[lowerBound..<upperBound]
    }

    private func iosAppRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
