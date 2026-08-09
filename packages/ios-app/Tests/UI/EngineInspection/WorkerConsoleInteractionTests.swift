import Foundation
import Testing
@testable import TronMobile

struct WorkerConsoleInteractionTests {
    @Test("Worker summaries turn protocol previews into readable user-facing text")
    func readableWorkerSummaryPresentation() {
        #expect(
            WorkerRunGraphPresentation.runTitle(
                workerName: "Continuity Curator",
                workerId: "continuity-curator"
            ) == "Continuity Curator"
        )
        #expect(
            WorkerRunGraphPresentation.runTitle(
                workerName: "  ",
                workerId: "continuity-curator"
            ) == "Continuity Curator"
        )
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
        #expect(fields.first?.type == "Text")
        #expect(
            fields.first(where: { $0.label == "Path/to~value" })?.pointer
                == "/path~1to~0value"
        )
        #expect(fields.first(where: { $0.label == "Path/to~value" })?.type == "Boolean")
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
                "Sources/UI/WorkerConsole/RunGraph/WorkerRunGraphComponents.swift"
            ),
            encoding: .utf8
        )
        let graphController = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/RunGraph/WorkerToolRunGraphView.swift"
            ),
            encoding: .utf8
        )
        let graph = graphComponents + graphController
        let tool = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/Tools/Invocation/ToolInvocationDetailSheet.swift"
            ),
            encoding: .utf8
        )
        let context = try sessionContextSource(root: root)
        let resultInspector = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerResultInspectorSheet.swift"
            ),
            encoding: .utf8
        )

        #expect(graph.contains("WorkerRunGraphSummaryView"))
        #expect(graph.contains("WorkerRunExecutionTraceView"))
        #expect(!graph.contains("WorkerRunCausalTreeView"))
        #expect(graph.contains("WorkerRunTimelineView"))
        #expect(graph.contains("entry.summary"))
        #expect(graph.contains("filter { !$0.technical }"))
        #expect(graph.contains("WorkerRunExecutionOverviewView"))
        #expect(graph.contains("WorkerRunExecutionSheet"))
        #expect(graph.contains("Inspect execution trace"))
        #expect(graph.contains("Open agent transcript"))
        #expect(graph.contains("prompts, responses, reasoning, and tool calls"))
        #expect(!graph.contains("Agent transcripts"))
        #expect(!graph.contains("Work structure"))
        #expect(!graph.contains("Activity history"))
        #expect(!graph.contains("WorkerRunDetailLinksView"))
        #expect(!graph.contains("WorkerRunTreeSheet"))
        #expect(!graph.contains("WorkerRunTimelineSheet"))
        #expect(tool.contains("WorkerToolRunGraphView("))
        #expect(graph.contains(".workerRunProjectionInvalidated"))
        #expect(graph.contains("WorkerRunGraphPresentation.shouldRefreshAfterInvalidation"))
        #expect(graph.contains("View complete result"))
        #expect(!graph.contains("Inspect result"))
        #expect(graph.contains("WorkerResultInspectorSheet("))
        #expect(graphController.contains("WorkerResultAgentHandoffButton("))
        #expect(!graphController.contains("loadResultOverview"))
        #expect(!graphController.contains("workerResult("))
        #expect(context.contains(".workerRunProjectionInvalidated"))
        #expect(!graph.contains("Started Filesystem"))
        #expect(!graph.contains("Finished Filesystem"))
        #expect(!graph.contains("joined(separator: \"\")"))
        #expect(!graphComponents.contains(#"Image(systemName: "arrow.up.right.square")"#))
        #expect(!resultInspector.contains(#"Image(systemName: "arrow.up.right.square")"#))
    }

    @Test("Worker run sheet leads with validated output and consolidates drill-down")
    func workerRunSheetUsesOneExecutionAndTechnicalHierarchy() throws {
        let root = iosAppRoot()
        let detail = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerConsoleDetailSheets.swift"
            ),
            encoding: .utf8
        )
        let technical = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerRunTechnicalDetailsSheet.swift"
            ),
            encoding: .utf8
        )
        let runSheet = try sourceSlice(
            detail,
            from: "struct WorkerRunDetailSheet: View",
            through: "private enum Mutation"
        )
        let resultPosition = try #require(
            runSheet.range(of: "WorkerRunInvocationResultView(")?.lowerBound
        )
        let executionPosition = try #require(
            runSheet.range(of: "WorkerRunInvocationExecutionOverviewView")?.lowerBound
        )

        #expect(resultPosition < executionPosition)
        #expect(runSheet.contains("WorkerRunInvocationSummaryView("))
        #expect(!runSheet.contains("summaryFallback"))
        #expect(!runSheet.contains("Loading authoritative run"))
        #expect(!runSheet.contains("loadResultOverview"))
        #expect(runSheet.contains("showExecutionDetails"))
        #expect(!runSheet.contains("showRunTree"))
        #expect(!runSheet.contains("showTimeline"))
        #expect(runSheet.contains("showsTechnicalDetails: false"))
        #expect(runSheet.contains("initialResultChunk: nil"))
        #expect(technical.contains("Validated result JSON"))
        #expect(technical.contains("Output schema"))
        #expect(technical.contains("Technical timeline"))
        #expect(technical.contains("Worker input"))
    }

    @Test("Execution trace exposes one transcript per distinct agent session")
    func executionTraceDeduplicatesTranscriptOwners() throws {
        let data = #"""
        [
          {"id":"invocation:root","kind":"invocation","status":"completed","elapsedMs":10,"sessionId":"session-root"},
          {"id":"agent:root","kind":"agent","status":"completed","elapsedMs":9,"sessionId":"session-root"},
          {"id":"model:root:1","kind":"model","status":"completed","elapsedMs":4,"sessionId":"session-root"},
          {"id":"invocation:child","kind":"invocation","status":"completed","elapsedMs":5,"sessionId":"session-child"},
          {"id":"agent:child","kind":"agent","status":"completed","elapsedMs":4,"sessionId":"session-child"}
        ]
        """#.data(using: .utf8)!
        let nodes = try JSONDecoder().decode([WorkerRunNodeDTO].self, from: data)

        #expect(
            WorkerRunGraphPresentation.transcriptOwnerNodeIds(nodes)
                == Set(["invocation:root", "invocation:child"])
        )
    }

    @Test("Engine containers do not use trailing navigation chevrons")
    func engineContainersOmitTrailingChevrons() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let files = try swiftSourcesRecursively(at: workerRoot)

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
        let files = try swiftSourcesRecursively(at: workerRoot)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "WorkerDetailSheet.swift" {
                #expect(source.contains("DisclosureGroup(isExpanded: $isLifecycleAuditExpanded)"))
                #expect(source.components(separatedBy: "DisclosureGroup").count == 2)
            } else {
                #expect(
                    !source.contains("DisclosureGroup"),
                    "\(file.lastPathComponent) must route unbounded detail to a sheet"
                )
            }
        }

        let detail = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("Presentation/WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("WorkerJSONDetailSheet(title: \"Input Schema\""))
        #expect(detail.contains("title: \"Use in a new chat\""))
        #expect(detail.contains("startAgentSessionHandoff(.worker("))
        #expect(!detail.contains("TextEditor(text: $viewModel.invocationInput)"))
        #expect(!detail.contains("title: \"New invocation\""))
        #expect(components.contains("Button(action: onOpen)"))
        #expect(!components.contains("WorkerRunDetailSheet("))
        #expect(components.contains("WorkerJSONDetailSheet("))

        let resultInspector = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerResultInspectorSheet.swift"),
            encoding: .utf8
        )
        #expect(resultInspector.contains("struct WorkerResultInspectorSheet"))
        #expect(resultInspector.contains("repository.workerResult("))
        #expect(resultInspector.contains("chunk.children"))
        #expect(resultInspector.contains("WorkerResultTechnicalSheet"))
        #expect(resultInspector.contains("Open raw JSON"))
        #expect(resultInspector.contains("Result fields"))
        #expect(resultInspector.contains("StructuredDataFieldHeader("))
        #expect(resultInspector.contains("title: \"Continue in a new chat\""))
        #expect(resultInspector.contains("startAgentSessionHandoff(.workerResult("))
        #expect(resultInspector.contains("struct WorkerResultAgentHandoffButton"))
        let handoffAction = try sourceSlice(
            resultInspector,
            from: "private func resultHandoffAction(",
            through: "private var resultPath: some View"
        )
        #expect(handoffAction.contains("WorkerConsoleSectionHeader("))
        #expect(handoffAction.contains("WorkerResultAgentHandoffButton("))
        #expect(!handoffAction.contains("WorkerConsoleSection("))
        #expect(!resultInspector.contains("Text(fieldMetadata(field))"))
        #expect(!resultInspector.contains(#"title: chunk.truncated ? "Result page" : "Result value""#))
        #expect(!resultInspector.contains("assembledResult"))
        let runDetail = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )
        let runTechnicalDetail = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerRunTechnicalDetailsSheet.swift"),
            encoding: .utf8
        )
        #expect(runDetail.contains("WorkerResultInspectorSheet("))
        #expect(runDetail.contains("WorkerResultAgentHandoffButton("))
        #expect(runDetail.contains("WorkerRunTechnicalDetailsSheet"))
        #expect(runTechnicalDetail.contains("Legacy Worker Result"))
        #expect(!runDetail.contains("Inspect typed result"))
        #expect(!runDetail.contains("Run result projection"))
        #expect(!runDetail.contains("showOutput"))

        let codeBlockSource = try String(
            contentsOf: workerRoot.appendingPathComponent("Presentation/WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        #expect(codeBlockSource.contains(".fixedSize(horizontal: true, vertical: true)"))
    }

    @Test("Worker controls use glass only outside nested glass containers")
    func workerControlsUseSharedLiquidGlass() throws {
        let root = iosAppRoot()
        let theme = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Theme/TronColors.swift"),
            encoding: .utf8
        )
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
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/Detail/WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let delegation = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/Domains/DelegationSheet.swift"),
            encoding: .utf8
        )

        #expect(theme.contains("var usesLiquidGlassForControls: Bool"))
        #expect(tabs.contains("GlassEffectContainer"))
        #expect(tabs.contains("@Environment(\\.usesLiquidGlassForControls)"))
        #expect(tabs.contains("optionsView(usesLiquidGlass: false)"))
        #expect(tabs.contains("TronGlassSelectionButtonStyle("))
        #expect(selectionStyle.contains(".glassEffect("))
        #expect(selectionStyle.contains("var usesLiquidGlass = true"))
        #expect(selectionStyle.contains("staticStyled("))
        #expect(action.contains(".glassEffect("))
        #expect(action.contains("@Environment(\\.usesLiquidGlassForControls)"))
        #expect(action.contains(".fill(accent.opacity(isEnabled ? 0.12 : 0.05))"))
        #expect(workerDetail.contains("TronPrimaryActionButton("))
        #expect(delegation.contains("TronPrimaryActionButton("))
        #expect(!workerDetail.contains(".background(Color.tronEmerald"))
        #expect(!delegation.contains(".background(Color.tronPurple"))
    }

    @Test("Engine summary owns availability without a redundant Overview tab")
    func engineSummaryReplacesOverviewTab() throws {
        let root = iosAppRoot()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/Overview/WorkerConsoleViews.swift"),
            encoding: .utf8
        )
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/Domains/EngineDashboardViews.swift"),
            encoding: .utf8
        )

        #expect(!shell.contains("case overview = \"Overview\""))
        #expect(shell.contains("selectedSection: EngineDashboardSection = .workers"))
        let workersCase = try #require(shell.range(of: "case workers = \"Workers\""))
        let primitivesCase = try #require(shell.range(of: "case primitives = \"Primitives\""))
        #expect(workersCase.lowerBound < primitivesCase.lowerBound)
        #expect(shell.contains("engineHookSummary"))
        #expect(shell.contains("private var summarySymbol: String"))
        #expect(shell.contains("\"cpu\""))
        #expect(!shell.contains("overviewContent"))
        #expect(!dashboard.contains("struct EngineSurfaceCard"))
    }

    @Test("Manage Session is high-level while content and audit details disclose progressively")
    func sessionContextSheetHierarchy() throws {
        let root = iosAppRoot()
        let context = try sessionContextSource(root: root)
        let mainSheet = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/SessionContext/SessionContextSheet.swift"
            ),
            encoding: .utf8
        )
        let detailSheet = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/SessionContext/SessionContextDetailSheet.swift"
            ),
            encoding: .utf8
        )
        let activitySheets = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/SessionContext/SessionContextActivitySheets.swift"
            ),
            encoding: .utf8
        )
        let modelPicker = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/Settings/ModelPicker/ModelPickerSheet.swift"
            ),
            encoding: .utf8
        )

        #expect(context.contains("label: currentModelId.shortModelName"))
        #expect(mainSheet.contains("ScrollView(.vertical, showsIndicators: true)"))
        #expect(mainSheet.contains(".containerRelativeFrame(.horizontal)"))
        #expect(mainSheet.contains(".scrollBounceBehavior(.basedOnSize, axes: .vertical)"))
        #expect(mainSheet.contains("SessionContextRefreshCoordinator()"))
        #expect(mainSheet.contains("@State var showBackgroundActivity"))
        #expect(mainSheet.contains("@State var showSessionWorkers"))
        #expect(mainSheet.contains("SessionContextBackgroundActivitySheet("))
        #expect(mainSheet.contains("SessionContextWorkersSheet("))
        #expect(activitySheets.contains("update.resultInvocationId"))
        #expect(activitySheets.contains("selectedResult = WorkerResultSelection"))
        #expect(activitySheets.contains(".sheet(item: $selectedResult)"))
        #expect(activitySheets.contains(".sheet(item: $selectedRun)"))
        #expect(mainSheet.contains("SessionContextContinuityKey("))
        #expect(mainSheet.contains("continuity: dependencies.connectionRepository.continuity"))
        #expect(!mainSheet.contains("workerRefreshRevision"))
        #expect(!context.contains("guard !isLoadingWorkerRuns"))
        #expect(!context.contains("guard !isLoadingAgentUpdates"))
        #expect(!context.contains("guard !isLoadingInspectableContext"))
        #expect(context.contains("catch is CancellationError"))
        #expect(context.contains("var wasActive = shouldContinueObservingDeliveryState"))
        #expect(!context.contains("requestAllSessionContextRefreshes()"))
        #expect(context.contains("requestActivatedSessionContextRefreshes()"))
        #expect(context.contains("requestActivatedLiveSessionStateRefreshes()"))
        #expect(context.contains("loadCachedContextOverview()"))
        #expect(context.contains("limit: 1"))
        #expect(mainSheet.contains("LazyVStack(spacing: SessionContextPresentation.sectionSpacing)"))
        #expect(context.contains("activateAgentUpdatesLane()"))
        #expect(context.contains("activateWorkerLane()"))
        #expect(mainSheet.contains("WorkerProjectionInvalidation.affectsSession"))
        #expect(mainSheet.contains("requestAgentUpdatesRefresh()"))
        #expect(mainSheet.contains("if phase == .active"))
        #expect(context.contains("Couldn’t refresh worker activity; showing the last update."))
        #expect(!context.contains("Window loading"))
        #expect(!context.contains("var modelSection: some View"))
        #expect(!context.contains("Latest model request"))
        #expect(!context.contains("showContextHistory"))
        #expect(!mainSheet.contains("SessionContextHistorySheet"))
        #expect(!mainSheet.contains("requestToolsSection"))
        #expect(context.contains(#"title: "Agent Context""#))
        #expect(context.contains(#"title: "Background Activity""#))
        #expect(context.contains(#"title: "Session Workers""#))
        #expect(context.contains(#"title: "Technical Details""#))
        #expect(!context.contains("chevron.right"))
        #expect(context.contains("projection: destination == .agentContext ? .agentContext : .technical"))
        #expect(context.contains("latestContextDetails[destination]"))
        #expect(!context.contains(#"title: "What the agent received""#))
        #expect(detailSheet.contains(#"technicalSection(title: "Redacted provider request")"#))
        #expect(detailSheet.contains(#"contextSection(title: "Available tools")"#))
        #expect(detailSheet.contains("destination: .toolSurface(manifest.toolSurface)"))
        #expect(detailSheet.contains("LazyVStack(alignment: .leading, spacing: 18)"))
        #expect(detailSheet.contains("No background worker or agent updates were included"))
        #expect(detailSheet.contains("Ordinary messages and question answers appear in Conversation"))
        #expect(detailSheet.contains("message.sourceModels.map"))
        #expect(detailSheet.contains("message.sourceTools.map"))
        let agentContext = try sourceSlice(
            detailSheet,
            from: "private func agentContext(",
            through: "private func technicalDetails("
        )
        #expect(!agentContext.contains("auditIdentifier("))
        #expect(!agentContext.contains("sha256"))
        #expect(!agentContext.contains("sourceEventIds"))
        #expect(detailSheet.contains(#"technicalSection(title: "Provider-visible environment")"#))
        #expect(detailSheet.contains("Filesystem paths and server origins are redacted"))
        #expect(detailSheet.contains(#"technicalSection(title: "Integrity")"#))
        #expect(detailSheet.contains(#"technicalSection(title: "Message provenance")"#))
        #expect(context.contains("SessionContextRawJSONSheet(selection: selection)"))
        #expect(context.contains("Task.detached(priority: .userInitiated)"))
        #expect(context.contains("textView.isScrollEnabled = true"))
        #expect(activitySheets.contains("ScrollView(.vertical, showsIndicators: true)"))
        #expect(activitySheets.contains(".containerRelativeFrame(.horizontal)"))
        #expect(detailSheet.contains("View included content"))
        #expect(detailSheet.contains("includedDeliverySummary"))
        #expect(context.contains("SessionContextPresentation.terminalAvailability("))
        #expect(!context.contains("if dependencies.terminalRepository.isSupported"))
        #expect(context.contains(#""Available after reconnection""#))
        #expect(mainSheet.contains("repository: dependencies.terminalRepository"))
        #expect(!context.contains("dependencies.engineClient"))
        #expect(modelPicker.contains("return Menu"))
        #expect(modelPicker.contains("ForEach(availableReasoningLevels"))
        #expect(!modelPicker.contains("ReasoningLevelPopover"))
        #expect(!modelPicker.contains("showReasoningPopover"))
    }

    @Test("Worker architecture is integrated into normal inventory and detail")
    func workerArchitectureIsIntegratedIntoWorkerInspection() throws {
        let root = iosAppRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleViews.swift"
            ),
            encoding: .utf8
        )
        let row = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleRow.swift"
            ),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerDetailSheet.swift"
            ),
            encoding: .utf8
        )
        let technicalDetail = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerTechnicalDetailsSheet.swift"
            ),
            encoding: .utf8
        )
        let context = try sessionContextSource(root: root)
        let standaloneSheet = root.appendingPathComponent(
            "Sources/UI/SessionContext/WorkerSystemSheet.swift"
        )

        #expect(!FileManager.default.fileExists(atPath: standaloneSheet.path))
        #expect(!engine.contains("Open Worker System"))
        #expect(engine.contains("viewModel.architecture(for: worker.workerId)"))
        #expect(engine.contains("architecture: architecture"))
        #expect(row.contains("Direct chat tool"))
        #expect(row.contains("Integrated worker"))
        #expect(row.contains("Delegated worker"))
        #expect(!row.contains("Image(systemName: status.systemImage)"))
        #expect(row.contains("FlowLayout(spacing: 5)"))
        #expect(!row.contains("VStack(alignment: .trailing, spacing: 4)"))
        #expect(row.contains("WorkerConsolePresentation.runnerLabel(worker.runnerKind)"))
        #expect(row.contains("FlowLayout(spacing: 8)"))
        #expect(row.contains("\"Version \\(WorkerConsolePresentation.compactIdentifier"))
        #expect(row.contains("architecture.engineHooks"))
        #expect(row.contains("architecture.clientActions"))
        #expect(!detail.contains("Role & connections"))
        #expect(!detail.contains("private var architecture"))
        #expect(detail.contains("showTechnicalDetails = true"))
        #expect(detail.contains(#"Text("View details")"#))
        #expect(detail.contains("WorkerTechnicalDetailsSheet("))
        #expect(!detail.contains(#"label: "Agent access""#))
        #expect(detail.contains(#"title: "Input contract""#))
        #expect(detail.contains("private func triggers"))
        #expect(technicalDetail.contains(#"label: "Agent access""#))
        #expect(technicalDetail.contains(#"label: "Execution""#))
        #expect(technicalDetail.contains(#"label: "Engine hooks""#))
        #expect(technicalDetail.contains(#"label: "Calls workers""#))
        #expect(technicalDetail.contains(#"label: "Called by workers""#))
        #expect(technicalDetail.contains(#"label: "Uses engine tools""#))
        #expect(technicalDetail.contains("Native boundaries"))
        #expect(technicalDetail.contains(".filter { $0.targetWorkerId != nil }"))
        #expect(technicalDetail.contains(".filter { $0.targetWorkerId == nil }"))
        #expect(technicalDetail.contains(#"guard !values.isEmpty else { return "None" }"#))
        #expect(technicalDetail.contains("architecture.hasIntegrationBoundary"))
        #expect(technicalDetail.contains("if !boundaries.isEmpty"))
        #expect(!technicalDetail.contains("if !architecture.calls.isEmpty"))
        #expect(!technicalDetail.contains("if !callers.isEmpty"))
        #expect(technicalDetail.contains(#"label: provenance.count == 1 ? "Source" : "Sources""#))
        #expect(!technicalDetail.contains(#"title: "Input contract""#))
        #expect(!technicalDetail.contains(#"title: "Triggers""#))
        #expect(technicalDetail.contains(".workerConsoleSheetPresentation()"))
        #expect(!detail.contains("FlowLayout(spacing: 6)"))
        #expect(!detail.contains("showProvenance"))
        #expect(!detail.contains("Source Details"))
        let versionMetadata = try #require(
            row.range(of: "\"Version \\(WorkerConsolePresentation.compactIdentifier")
        )
        let triggerMetadata = try #require(
            row.range(of: "WorkerConsolePresentation.triggerLabel(worker.triggerCount)")
        )
        let tags = try #require(row.range(of: "FlowLayout(spacing: 5)"))
        #expect(versionMetadata.lowerBound < triggerMetadata.lowerBound)
        #expect(triggerMetadata.lowerBound < tags.lowerBound)
        let triggerStart = try #require(detail.range(of: "private func triggers"))
        let handoffStart = try #require(detail.range(of: "private func useInChat"))
        let triggerSource = detail[triggerStart.lowerBound..<handoffStart.lowerBound]
        #expect(triggerSource.contains("WorkerConsoleGroup("))
        #expect(triggerSource.contains("WorkerConsoleInlineEmptyState"))
        #expect(!triggerSource.contains("WorkerConsoleSection("))
        #expect(!context.contains("WorkerSystemSheet("))
        #expect(!context.contains("workerSystemSection"))
    }

    @Test("Covered production worker sheets freeze observation and render lazily")
    func coveredWorkerSheetsFreezeAndRenderLazily() throws {
        let root = iosAppRoot()
        let components = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Presentation/WorkerConsoleComponents.swift"
            ),
            encoding: .utf8
        )
        let console = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleViews.swift"
            ),
            encoding: .utf8
        )
        let delegation = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Domains/DelegationSheet.swift"
            ),
            encoding: .utf8
        )
        let research = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Domains/ResearchSuiteSheet.swift"
            ),
            encoding: .utf8
        )
        let runDetail = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerConsoleDetailSheets.swift"
            ),
            encoding: .utf8
        )
        let toolRun = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/RunGraph/WorkerToolRunGraphView.swift"
            ),
            encoding: .utf8
        )
        let workerRow = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleRow.swift"
            ),
            encoding: .utf8
        )
        let theme = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/Theme/TronColors.swift"
            ),
            encoding: .utf8
        )

        #expect(components.contains("func workerConsoleSheetPresentation()"))
        #expect(components.contains("firstLevelGlassSectionFills()"))
        #expect(components.contains(".adaptivePresentationDetents([.medium, .large]"))
        #expect(theme.contains("case firstLevelOnly"))
        #expect(theme.contains("return sectionFillDepth == 0"))
        #expect(theme.contains(
            "environment(\\.sectionFillDepth, sectionFillDepth + 1)"
        ))
        #expect(!workerRow.contains(".glassEffect("))
        #expect(!toolRun.contains(".glassEffect("))
        #expect(console.contains("LazyVStack(alignment: .leading"))
        #expect(delegation.contains("LazyVStack(alignment: .leading"))
        #expect(research.contains("LazyVStack(alignment: .leading"))
        #expect(!console.contains(".workLedger"))

        #expect(console.contains("isCovered: isPresentingChildSheet"))
        #expect(console.contains("guard !isPresentingChildSheet else { return }"))
        #expect(delegation.contains(#"workerProjection: "covered""#))
        #expect(delegation.contains("guard !isPresentingChildSheet else { return }"))
        #expect(research.contains(#"workerProjection: "covered""#))
        #expect(research.contains("guard !isPresentingChildSheet else { return }"))
        #expect(runDetail.contains("WorkerRunDetailRefreshKey("))
        #expect(runDetail.contains("isCovered: isPresentingChildSheet,"))
        #expect(runDetail.contains("continuity: dependencies.connectionRepository.continuity"))
        #expect(runDetail.contains("if !isPresentingChildSheet,"))
        #expect(toolRun.contains("WorkerToolRunGraphRefreshKey("))
        #expect(toolRun.contains("isCovered: isPresentingChildSheet,"))
        #expect(toolRun.contains("continuity: dependencies.connectionRepository.continuity"))
        #expect(toolRun.contains("if !isPresentingChildSheet,"))
    }

    @Test("Artifact inbox uses Settings styling and new-chat handoffs")
    func artifactInboxUsesStandardSettingsPresentation() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/UI/WorkerConsole/Domains/ArtifactInboxViews.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("SettingsPageContainer(title: \"Artifacts\""))
        #expect(source.contains("SettingsCard(accent: .tronEmerald"))
        #expect(source.contains("TronTypography.sans"))
        #expect(source.contains("Create through chat"))
        #expect(source.contains("startAgentSessionHandoff(.newArtifact)"))
        #expect(source.contains("struct ArtifactPreviewSheet: View"))
        #expect(!source.contains("ArtifactDetailView"))
        #expect(!source.contains("ArtifactExportDocument"))
        #expect(source.contains("ArtifactContentPreview(materialized: content)"))
        #expect(source.contains("TextContentView(text: text, role: .assistant)"))
        #expect(source.contains("Continue in New Chat"))
        #expect(source.contains("startAgentSessionHandoff(.artifact("))
        #expect(source.contains(".workerConsoleSheetPresentation()"))
        #expect(source.contains(".safeAreaInset(edge: .bottom"))
        #expect(source.contains("ArtifactActivitySheet(url: item.url)"))
        #expect(source.contains("UIActivityViewController(activityItems: [url]"))
        #expect(!source.contains("ShareLink(item: url)"))
        #expect(source.contains("TronScrollEdgeEffects.applySoftToDescendantScrollViews"))
        #expect(source.contains(".glassEffect("))
        #expect(!source.contains("ArtifactQuickLookView(url: url)\n                    .ignoresSafeArea()"))
    }

    @Test("Agent-session handoffs admit only one chat creation at a time")
    func agentSessionHandoffsAreSingleFlight() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/UI/Chat/Shell/ContentView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("guard !isCreatingAgentSessionHandoff else { return }"))
        #expect(source.contains("defer { isCreatingAgentSessionHandoff = false }"))
    }

    @Test("Engine dashboard renders retired workers in a final dedicated section")
    func engineDashboardSeparatesRetiredWorkers() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleViews.swift"
            ),
            encoding: .utf8
        )

        let generalRange = try #require(source.range(of: "workerRows(viewModel.generalWorkers)"))
        let integratedTitleRange = try #require(source.range(of: "title: \"Integrated workers\""))
        let integratedRowsRange = try #require(source.range(of: "workerRows(viewModel.integratedWorkers)"))
        let retiredTitleRange = try #require(source.range(of: "title: \"Retired workers\""))
        let retiredRowsRange = try #require(source.range(of: "workerRows(viewModel.retiredWorkers)"))

        #expect(generalRange.lowerBound < integratedTitleRange.lowerBound)
        #expect(integratedTitleRange.lowerBound < integratedRowsRange.lowerBound)
        #expect(integratedRowsRange.lowerBound < retiredTitleRange.lowerBound)
        #expect(retiredTitleRange.lowerBound < retiredRowsRange.lowerBound)
        #expect(source.contains("Inactive workers retained for audit, version history, and restoration."))
    }

    @Test("Active worker version status aligns with rollback controls")
    func activeWorkerVersionStatusUsesControlHeight() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/UI/WorkerConsole/Presentation/WorkerConsoleComponents.swift"
            ),
            encoding: .utf8
        )
        let row = try sourceSlice(
            source,
            from: "struct WorkerVersionRow: View",
            through: "private var isActive"
        )

        #expect(row.contains("HStack(alignment: .center"))
        #expect(row.contains(".frame(width: 82, height: 42, alignment: .center)"))
        #expect(!row.contains(".frame(minHeight:"))
    }

    @Test("Lifecycle history wraps from one leading edge")
    func lifecycleHistoryUsesLeadingAlignment() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/UI/WorkerConsole/Detail/WorkerDetailSheet.swift"
            ),
            encoding: .utf8
        )
        let label = try sourceSlice(
            source,
            from: "Text(\"Lifecycle history\")",
            through: ".frame(maxWidth: .infinity, alignment: .leading)"
        )

        #expect(label.contains(".multilineTextAlignment(.leading)"))
        #expect(label.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    @Test("Worker sessions stay read only and inside dashboard sheets")
    func workerSessionsUseReadOnlySheets() throws {
        let root = iosAppRoot()
        let details = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/Detail/WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )
        let executionTrace = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/UI/WorkerConsole/RunGraph/WorkerRunGraphComponents.swift"
            ),
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
        #expect(!details.contains("label: \"Open Chat\""))
        #expect(executionTrace.contains("Open agent transcript"))
        #expect(executionTrace.contains("node.sessionId"))
        #expect(executionTrace.contains("accent: .tronPurple"))
        #expect(!details.contains("title: \"Model Context\""))
        #expect(!details.contains("Open model context"))
        #expect(chat.contains("reconstructReadOnlyTranscript"))
        #expect(chat.contains("if presentationMode == .interactiveSession"))
        #expect(chat.contains("if presentationMode == .workerAudit"))
        #expect(chat.contains("content.tronScreenBackground()"))
        #expect(chatHelpers.contains("if presentationMode == .workerAudit"))
        #expect(chatHelpers.contains("[INIT] Worker audit loaded with"))
        #expect(chatHelpers.contains("bottom-anchored messages"))
        #expect(!chatHelpers.contains("positionScrollAtTop()"))
        #expect(messageList.contains("workerAuditMessagesScrollView"))
        #expect(messageList.contains("ScrollView(.vertical)"))
        #expect(messageList.contains("Load earlier activity"))
        #expect(messageList.contains("for: .initialOffset"))
        #expect(messageList.contains("for: .alignment"))
        #expect(!sidebar.contains("openWorkerAuditSession"))
        #expect(!content.contains("openWorkerAuditSession"))
    }

    @Test("Engine separates execution activity from classified durable results")
    func activityAndResultsHaveIndependentDestinations() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let shell = try String(
            contentsOf: workerRoot.appendingPathComponent("Overview/WorkerConsoleViews.swift"),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let audit = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )

        #expect(shell.contains("title: \"Worker runs\""))
        #expect(shell.contains("case results = \"Results\""))
        #expect(shell.contains("title: \"Needs attention\""))
        #expect(shell.contains("title: \"Available\""))
        #expect(shell.contains("title: \"Used by agent\""))
        #expect(shell.contains("title: \"Resolved\""))
        #expect(shell.contains("refreshResults("))
        #expect(shell.contains("monitorResults("))
        #expect(shell.contains("label: \"Unhealthy\""))
        #expect(!shell.contains("Text(\"Open delivery audit\")"))
        #expect(detail.contains("private var workerResults: some View"))
        #expect(detail.contains("case results"))
        #expect(detail.contains("private func lifecycleAudit"))
        #expect(detail.contains("private var inboxAudit: some View"))
        #expect(!shell.contains("title: \"Durable inbox\""))
        #expect(!detail.contains("title: \"Durable inbox\""))
        #expect(audit.contains("struct WorkerInboxAuditSheet"))
        #expect(audit.contains("attentionOnly: false"))
    }

    @Test("Lazy worker rows emit open intents while stable parents own detail sheets")
    func workerRowsDoNotOwnReloadableSheets() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("Presentation/WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        let shell = try String(
            contentsOf: workerRoot.appendingPathComponent("Overview/WorkerConsoleViews.swift"),
            encoding: .utf8
        )
        let runCard = try sourceSlice(
            components,
            from: "struct WorkerRunCard: View",
            through: "struct WorkerInboxCard: View"
        )
        let inboxCard = try sourceSlice(
            components,
            from: "struct WorkerInboxCard: View",
            through: "extension WorkerResultDisposition"
        )

        #expect(runCard.contains("let onOpen: () -> Void"))
        #expect(inboxCard.contains("let onOpen: () -> Void"))
        #expect(!runCard.contains(".sheet("))
        #expect(!inboxCard.contains(".sheet("))
        #expect(shell.contains("@State private var selectedRun"))
        #expect(shell.contains("@State private var selectedInboxItem"))
        #expect(shell.contains(".sheet(item: $selectedRun)"))
        #expect(shell.contains(".sheet(item: $selectedInboxItem)"))
    }

    @Test("Run cards use compact operational metadata while delegated tasks retain one leading edge")
    func workerActivityCardsUseDeliberateTextAlignment() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("Presentation/WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        let delegation = try String(
            contentsOf: workerRoot.appendingPathComponent("Domains/DelegationSheet.swift"),
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
        #expect(workerRunCard.contains("runCompactMetadata"))
        #expect(workerRunCard.contains("timestamp(run.createdAt)"))
        #expect(workerRunCard.contains(".lineLimit(1)"))
        #expect(!workerRunCard.contains("runFact"))
        #expect(!workerRunCard.contains("Capsule()"))
        #expect(!workerRunCard.contains("\"Invoked by\""))
        #expect(!workerRunCard.contains("compactRunIdentifier"))
        #expect(delegationRunRow.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    @Test("Worker activity and lifecycle cards own their first-level glass surfaces")
    func workerDetailAvoidsNestedGlassCardGroups() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let detail = try String(
            contentsOf: workerRoot.appendingPathComponent("Detail/WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("Presentation/WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        let activity = try sourceSlice(
            detail,
            from: "private var recentRuns: some View",
            through: "private var inboxAudit: some View"
        )
        let lifecycleAudit = try sourceSlice(
            detail,
            from: "private func lifecycleAudit",
            through: "private var inboxAudit"
        )
        let group = try sourceSlice(
            components,
            from: "struct WorkerConsoleGroup<Content: View>: View",
            through: "extension View"
        )

        #expect(activity.contains("WorkerConsoleGroup("))
        #expect(!activity.contains("WorkerConsoleSection("))
        #expect(lifecycleAudit.contains("DisclosureGroup(isExpanded: $isLifecycleAuditExpanded)"))
        #expect(lifecycleAudit.contains("sectionFill(.tronPurple"))
        #expect(!lifecycleAudit.contains("WorkerConsoleSection("))
        #expect(group.contains("WorkerConsoleSectionHeader"))
        #expect(!group.contains("sectionFill"))
    }

    @Test("Worker experience summaries separate current attention from retained history")
    func workerExperienceSummariesUseCurrentAttention() throws {
        let workerRoot = iosAppRoot().appendingPathComponent("Sources/UI/WorkerConsole")
        let delegation = try String(
            contentsOf: workerRoot.appendingPathComponent("Domains/DelegationSheet.swift"),
            encoding: .utf8
        )
        let research = try String(
            contentsOf: workerRoot.appendingPathComponent("Domains/ResearchSuiteSheet.swift"),
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
            .deletingLastPathComponent()
    }

    private func swiftSourcesRecursively(at root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            return []
        }
        return try enumerator.compactMap { item in
            guard
                let url = item as? URL,
                url.pathExtension == "swift",
                try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
            else {
                return nil
            }
            return url
        }
    }

    private func sessionContextSource(root: URL) throws -> String {
        try swiftSourcesRecursively(
            at: root.appendingPathComponent("Sources/UI/SessionContext")
        )
        .sorted { $0.path < $1.path }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
    }
}
