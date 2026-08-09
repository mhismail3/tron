import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class ToolInvocationDetailViewTests: XCTestCase {
    private var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "tool-detail-render")
        testState.registerTeardown(with: self)
    }

    override func tearDown() async throws {
        await testState.cleanup()
        testState = nil
    }

    func testToolInvocationDetailSourceUsesEvidencePresentationMapper() throws {
        let source = try source(pathComponents: ["Sources", "UI", "Tools", "Invocation", "ToolInvocationDetailSheet.swift"])

        XCTAssertTrue(source.contains("ToolEvidencePresentation(data: data)"))
        XCTAssertTrue(source.contains("ToolInvocationBriefPresentation(data: data)"))
        XCTAssertTrue(source.contains("ToolStructuredDocumentView"))
        XCTAssertTrue(source.contains("progressSection"))
        XCTAssertTrue(source.contains("ToolProgressJourneyView"))
        XCTAssertTrue(source.contains(#""Live activity""#))
        XCTAssertTrue(source.contains(#""Current state""#))
        XCTAssertTrue(source.contains(#""Outcome""#))
        XCTAssertTrue(source.contains("ToolTechnicalDetailsSheet"))
        XCTAssertTrue(source.contains("ToolRawDetailLink"))
        XCTAssertTrue(source.contains(#""Technical details""#))
        XCTAssertTrue(source.contains(#""Run identifiers""#))
        XCTAssertTrue(source.contains(#""Protocol references""#))
        XCTAssertTrue(source.contains(#""Raw request""#))
        XCTAssertTrue(source.contains(#""Raw result""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Evidence""#))
        XCTAssertFalse(source.contains("ToolRowsDetailLink"))
        XCTAssertFalse(source.contains("ToolRowsDetailSheet"))
        XCTAssertFalse(source.contains("DisclosureGroup"))
        XCTAssertFalse(source.contains(#"Image(systemName: "arrow.up.right.square")"#))
        XCTAssertFalse(source.contains("ForEach(evidence.sections)"))
        XCTAssertFalse(source.contains("ToolInvocationCodeBlock(text: body)"))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Target""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Action""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Runtime Details""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Advanced""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "What happened""#))
        XCTAssertFalse(source.contains(#"title: surface.isWorker ? "Worker input" : "Request""#))
        XCTAssertFalse(source.contains("Approval state"))
    }

    func testParsedJSONFieldsUseSharedTrailingTypeHierarchy() throws {
        let header = try source(pathComponents: [
            "Sources", "UI", "Components", "StructuredDataFieldHeader.swift",
        ])
        XCTAssertTrue(header.contains("Spacer(minLength: 12)"))
        XCTAssertTrue(header.contains("Text(type)"))
        XCTAssertTrue(header.contains(".multilineTextAlignment(.trailing)"))
        XCTAssertFalse(header.contains("Capsule()"))

        let toolResults = try source(pathComponents: [
            "Sources", "UI", "Tools", "ToolResultRenderers.swift",
        ])
        XCTAssertEqual(
            occurrences(of: "StructuredDataFieldHeader(", in: toolResults),
            2
        )

        let workerResults = try source(pathComponents: [
            "Sources", "UI", "WorkerConsole", "Detail",
            "WorkerResultInspectorSheet.swift",
        ])
        XCTAssertTrue(workerResults.contains("StructuredDataFieldHeader("))

        let workerComponents = try source(pathComponents: [
            "Sources", "UI", "WorkerConsole", "Presentation",
            "WorkerConsoleComponents.swift",
        ])
        XCTAssertTrue(workerComponents.contains("StructuredDataFieldHeader("))
        XCTAssertFalse(workerComponents.contains("Capsule().fill(Color.tronInfo.opacity(0.12))"))
    }

    func testToolDetailSectionUsesLiquidGlassSurfaceForStableDetailNavigation() throws {
        let source = try source(pathComponents: ["Sources", "UI", "Tools", "Shared", "ToolDetailSection.swift"])

        XCTAssertTrue(source.contains(".sectionFill(accent"))
        XCTAssertTrue(source.contains("payload or evidence detail opens in nested sheets"))
        XCTAssertFalse(source.contains("Color.tronSurface.opacity(0.86)"))
    }

    func testToolDetailDestinationsStartAtMediumAndOfferLarge() throws {
        let mediumAndLarge =
            ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
        let largeOnly =
            ".adaptivePresentationDetents([.large], ipadSizing: .largeForm)"

        let directPresentationSources: [(String, Int)] = [
            (
                try source(pathComponents: [
                    "Sources", "UI", "Tools", "Shared", "ToolDetailSheetContainer.swift",
                ]),
                1
            ),
            (
                try source(pathComponents: [
                    "Sources", "UI", "Tools", "ToolInvocationDetailComponents.swift",
                ]),
                1
            ),
            (
                try source(pathComponents: [
                    "Sources", "UI", "Tools", "Invocation", "ToolInvocationDetailSheet.swift",
                ]),
                1
            ),
        ]

        for (sheetSource, expectedCount) in directPresentationSources {
            XCTAssertEqual(occurrences(of: mediumAndLarge, in: sheetSource), expectedCount)
            XCTAssertFalse(sheetSource.contains(largeOnly))
        }

        let sharedPresentationSources: [(String, Int)] = [
            (
                try source(pathComponents: [
                    "Sources", "UI", "WorkerConsole", "RunGraph", "WorkerRunGraphComponents.swift",
                ]),
                1
            ),
            (
                try source(pathComponents: [
                    "Sources", "UI", "WorkerConsole", "Detail", "WorkerResultInspectorSheet.swift",
                ]),
                2
            ),
            (
                try source(pathComponents: [
                    "Sources", "UI", "WorkerConsole", "Detail", "WorkerJSONDetailSheet.swift",
                ]),
                1
            ),
        ]

        for (sheetSource, expectedCount) in sharedPresentationSources {
            XCTAssertEqual(
                occurrences(of: ".workerConsoleSheetPresentation()", in: sheetSource),
                expectedCount
            )
            XCTAssertFalse(sheetSource.contains(largeOnly))
        }

        let workerDetails = try source(pathComponents: [
            "Sources", "UI", "WorkerConsole", "Detail", "WorkerConsoleDetailSheets.swift",
        ])
        let auditSheet = try XCTUnwrap(
            workerDetails.components(separatedBy: "struct WorkerAuditSessionSheet").last
        )
        XCTAssertEqual(
            occurrences(of: ".workerConsoleSheetPresentation()", in: auditSheet),
            1
        )
        XCTAssertFalse(auditSheet.contains(largeOnly))
    }

    func testToolInvocationDetailRendersActionFirstSummaryForVisualQA() throws {
        let size = CGSize(width: 430, height: 932)
        let view = ToolInvocationDetailSheet(data: Self.fixtureInvocation)
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .systemBackground))

        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertEqual(image.size.width, size.width)
        XCTAssertEqual(image.size.height, size.height)

        let outputURL = try visualArtifactURL(outputName: "tool-invocation-detail-action-render.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    func testToolInvocationGroupRendersCompactGlassRowsForVisualQA() throws {
        let size = CGSize(width: 430, height: 932)
        let view = ToolInvocationGroupDetailSheet(data: Self.fixtureInvocationGroup)
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .systemBackground))

        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertEqual(image.size.width, size.width)
        XCTAssertEqual(image.size.height, size.height)

        let outputURL = try visualArtifactURL(outputName: "tool-invocation-group-glass-render.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    func testWorkerRunSummaryRendersProgressiveDisclosureForVisualQA() throws {
        let size = CGSize(width: 430, height: 932)
        let run = Self.fixtureWorkerRun
        let view = NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkerRunInvocationSummaryView(run: run)
                    WorkerRunInvocationResultView(run: run, inspectResult: {})
                    WorkerRunInvocationExecutionOverviewView(isReady: true, openDetails: {})
                }
                .padding(18)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemBackground))

        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }

        XCTAssertEqual(image.size.width, size.width)
        XCTAssertEqual(image.size.height, size.height)

        let outputURL = try visualArtifactURL(outputName: "worker-run-progressive-detail-render.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        let attachment = XCTAttachment(contentsOfFile: outputURL)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static var fixtureInvocation: ToolInvocationData {
        ToolInvocationData(
            id: "cap-work-detail",
            status: .success,
            arguments: #"""
            {
              "target": "process::run",
              "intent": "Check repository status.",
              "arguments": {
                "command": "git status --short",
                "executionMode": "read_only"
              },
              "reason": "User asked for current repository state."
            }
            """#,
            result: #"{"exitCode":0,"stdout":"clean\n","stderr":"","timedOut":false,"outputTruncated":false}"#,
            details: [
                "status": "ok",
                "output": [
                    "exitCode": 0,
                    "stdout": "clean\n",
                    "stderr": "",
                    "timedOut": false,
                    "outputTruncated": false
                ]
            ],
            durationMs: 86,
            identity: ToolIdentity(
                toolName: "process_run",
                traceId: "trace-process",
                presentationHints: [
                    "surfaceKind": "core",
                    "primitiveGroup": "host"
                ]
            )
        )
    }

    private static var fixtureInvocationGroup: ToolInvocationGroupData {
        ToolInvocationGroupData(invocations: [
            ToolInvocationData(
                id: "cap-group-worker-discover",
                status: .success,
                arguments: #"""
                {
                  "query": "recent research worker",
                  "limit": 5
                }
                """#,
                result: "Worker discovery returned 3 relevant persistent workers.",
                durationMs: 46,
                identity: ToolIdentity(
                    toolName: "worker_discover",
                    traceId: "trace-worker-discover"
                )
            ),
            ToolInvocationData(
                id: "cap-group-worker-list",
                status: .success,
                arguments: #"""
                {
                  "includeRetired": true
                }
                """#,
                result: "Worker list returned 4 persistent workers.",
                durationMs: 38,
                identity: ToolIdentity(
                    toolName: "worker_list",
                    traceId: "trace-worker-list"
                )
            ),
            ToolInvocationData(
                id: "cap-group-process-run",
                status: .success,
                arguments: #"""
                {
                  "command": ["git", "status", "--short"],
                  "timeoutSeconds": 30
                }
                """#,
                result: "Git status is clean.",
                durationMs: 78,
                identity: ToolIdentity(
                    toolName: "process_run",
                    traceId: "trace-process-run"
                )
            ),
            ToolInvocationData(
                id: "cap-group-worker-invoke",
                status: .error,
                arguments: #"""
                {
                  "workerId": "recent-research",
                  "input": {}
                }
                """#,
                result: "worker input schema requires property topic",
                details: [
                    "error": "worker input schema requires property topic",
                    "category": "invalid_request",
                    "recoverable": true,
                    "code": "ENGINE_SCHEMA_VIOLATION"
                ],
                durationMs: 12,
                identity: ToolIdentity(
                    toolName: "worker_invoke",
                    traceId: "trace-worker-invoke"
                ),
                errorClassification: ToolErrorClassification(
                    code: "ENGINE_SCHEMA_VIOLATION",
                    category: "invalid_request",
                    message: "worker input schema requires property topic",
                    recoverable: true
                )
            )
        ])
    }

    private static var fixtureWorkerGraph: WorkerRunGraphDTO {
        let data = #"""
        {
          "rootInvocationId": "worker_run_fixture",
          "requestedInvocationId": "worker_run_fixture",
          "modelToolInvocationId": "tool_fixture",
          "originSessionId": "session_fixture",
          "workerId": "research-coordinator",
          "workerName": "Research Coordinator",
          "requestPreview": "{\"budget\":\"high\",\"question\":\"Compare contradictory reporting across six independent sources.\",\"depth\":\"deep\"}",
          "status": "completed",
          "mode": "background",
          "stage": "completed",
          "stageLabel": "Worker execution completed",
          "expectedNextTransition": null,
          "createdAt": "2026-07-25T06:23:17Z",
          "startedAt": "2026-07-25T06:23:17Z",
          "completedAt": "2026-07-25T06:37:58Z",
          "elapsedMs": 881000,
          "counts": {
            "queued": 0,
            "running": 0,
            "completed": 5,
            "failed": 0,
            "cancelled": 0
          },
          "timing": {
            "queueMs": 13,
            "executionMs": 880987,
            "wallMs": 881000,
            "modelMs": 510000,
            "childCriticalPathMs": 180000,
            "criticalPathMs": 881000,
            "criticalPathNodeIds": ["invocation:worker_run_fixture"]
          },
          "usage": {
            "inputTokens": 12000,
            "outputTokens": 2400,
            "cacheReadTokens": 0,
            "cacheCreationTokens": 0,
            "cost": 0.42
          },
          "nodes": [
            {
              "id": "invocation:worker_run_fixture",
              "kind": "invocation",
              "parentId": null,
              "invocationId": "worker_run_fixture",
              "workerId": "research-coordinator",
              "workerName": "Research Coordinator",
              "workerVersion": "version",
              "runner": "agent",
              "status": "completed",
              "mode": "background",
              "stage": "completed",
              "createdAt": "2026-07-25T06:23:17Z",
              "startedAt": "2026-07-25T06:23:17Z",
              "completedAt": "2026-07-25T06:37:58Z",
              "elapsedMs": 881000
            }
          ],
          "timeline": [
            {
              "occurredAt": "2026-07-25T06:23:17Z",
              "nodeId": "invocation:worker_run_fixture",
              "stage": "queued",
              "status": "queued",
              "summary": "Queued for durable worker execution",
              "technical": false,
              "invocationId": "worker_run_fixture"
            },
            {
              "occurredAt": "2026-07-25T06:37:58Z",
              "nodeId": "invocation:worker_run_fixture",
              "stage": "completed",
              "status": "completed",
              "summary": "Worker execution completed",
              "technical": false,
              "invocationId": "worker_run_fixture"
            }
          ],
          "resultPreview": "research.report.v1 · partial · The reviewed evidence supports a bounded conclusion while identifying two unresolved claims.",
          "errorPreview": null,
          "truncated": false
        }
        """#.data(using: .utf8)!
        return try! JSONDecoder().decode(WorkerRunGraphDTO.self, from: data)
    }

    private static var fixtureWorkerRun: WorkerInvocationDTO {
        WorkerInvocationDTO(
            invocationId: "worker_run_fixture",
            workerId: "research-coordinator",
            workerVersion: "version",
            status: "completed",
            input: AnyCodable([
                "request": "Review the evidence and produce a bounded conclusion.",
            ]),
            output: AnyCodable([
                "status": "partial",
                "summary": "The evidence supports a bounded conclusion while two claims remain unresolved.",
            ]),
            error: nil,
            idempotencyKey: "worker-run-fixture",
            traceId: "trace-fixture",
            causalDepth: 0,
            triggerKind: "manual",
            originSessionId: "origin-session",
            agentSessionId: "worker-session",
            interactionMode: "background",
            requestedModel: "openai/gpt-5.6-sol",
            requestedReasoningLevel: "medium",
            effectiveModel: "openai/gpt-5.6-sol",
            effectiveReasoningLevel: "medium",
            attemptCount: 1,
            createdAt: "2026-08-08T13:49:00Z",
            startedAt: "2026-08-08T13:49:01Z",
            completedAt: "2026-08-08T13:50:17Z"
        )
    }

    private func visualArtifactURL(outputName: String) throws -> URL {
        try testState.artifactURL(named: outputName)
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try projectRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
