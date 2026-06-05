import SwiftUI
import XCTest
@testable import TronMobile

@available(iOS 26.0, *)
@MainActor
final class WorkDashboardViewTests: XCTestCase {
    func testWorkDashboardSourceUsesWorkerFirstVocabulary() throws {
        let content = try source(pathComponents: ["Sources", "Views", "Work", "WorkDashboardView.swift"])
        let navigation = try source(pathComponents: ["Sources", "Views", "Chat", "SessionSidebar.swift"])
        let root = try source(pathComponents: ["Sources", "Views", "Chat", "ContentView.swift"])
        let agentClient = try source(pathComponents: ["Sources", "Services", "Network", "Clients", "AgentClient.swift"])

        XCTAssertTrue(navigation.contains("case work = \"Work\""))
        XCTAssertTrue(root.contains("WorkDashboardView("))
        XCTAssertTrue(agentClient.contains(#""agent::work_snapshot""#))
        XCTAssertTrue(content.contains("WorkAutonomyPanel"))
        XCTAssertTrue(content.contains("WorkWorkersPanel"))
        XCTAssertTrue(content.contains("WorkWorkerDetailSheet"))
        XCTAssertTrue(content.contains("Generated Controls"))
        XCTAssertTrue(content.contains("Trust"))
        XCTAssertTrue(content.contains("Guardrails"))
        XCTAssertTrue(content.contains("WorkGuardrailsPanel"))
        XCTAssertTrue(content.contains("Audit Details"))
        XCTAssertFalse(content.contains("AuditDetailsMetricGrid"))
        XCTAssertFalse(content.contains("Substrate"))
        XCTAssertFalse(content.contains("Primer"))
        XCTAssertFalse(content.contains("Bindings"))
    }

    func testWorkDashboardRendersForIPhoneAndIPadVisualQA() throws {
        try renderWorkDashboard(
            size: CGSize(width: 430, height: 932),
            outputName: "work-dashboard-iphone-render.png"
        )
        try renderWorkDashboard(
            size: CGSize(width: 1194, height: 834),
            outputName: "work-dashboard-ipad-render.png"
        )
    }

    func testWorkerDetailRendersStateMatrixForVisualQA() throws {
        try renderWorkerDetail(
            worker: Self.worker(status: "Running", health: "healthy"),
            milestones: [],
            guardrails: [],
            outputName: "worker-detail-running-render.png"
        )
        try renderWorkerDetail(
            worker: Self.worker(status: "Completed", health: "healthy"),
            milestones: [Self.milestone(status: "completed")],
            guardrails: [],
            outputName: "worker-detail-success-render.png"
        )
        try renderWorkerDetail(
            worker: Self.worker(status: "Failed", health: "unhealthy", abilityHealth: "Unhealthy"),
            milestones: [Self.milestone(status: "failed")],
            guardrails: [],
            outputName: "worker-detail-failure-render.png"
        )
        try renderWorkerDetail(
            worker: Self.worker(status: "Waiting", health: "degraded", abilityHealth: "Degraded"),
            milestones: [],
            guardrails: [Self.guardrail()],
            outputName: "worker-detail-blocked-render.png"
        )
    }

    private func renderWorkDashboard(size: CGSize, outputName: String) throws {
        let view = NavigationStack {
            WorkDashboardContent(
                snapshot: Self.snapshot,
                loadState: .loaded,
                onSelectWorker: { _ in },
                onAudit: {}
            )
            .navigationTitle("Work")
            .navigationBarTitleDisplayMode(.inline)
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

        let outputURL = try visualArtifactURL(outputName: outputName)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    private func renderWorkerDetail(
        worker: WorkWorkerDTO,
        milestones: [WorkMilestoneDTO],
        guardrails: [WorkGuardrailDTO],
        outputName: String
    ) throws {
        let size = CGSize(width: 430, height: 932)
        let view = WorkWorkerDetailSheet(
            worker: worker,
            milestones: milestones,
            guardrails: guardrails
        )
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

        let outputURL = try visualArtifactURL(outputName: outputName)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    private func visualArtifactURL(outputName: String) throws -> URL {
        let documentsURL = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let artifactRoot = ProcessInfo.processInfo.environment["TRON_VISUAL_ARTIFACT_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? documentsURL.appendingPathComponent("tron-visual-artifacts")
        return artifactRoot.appendingPathComponent(outputName)
    }

    private static var snapshot: WorkSnapshotDTO {
        WorkSnapshotDTO(
            autonomy: WorkAutonomyDTO(
                mode: "independent",
                approvalPromptMode: "disabled",
                interactiveApprovalPrompts: false,
                statusLabel: "Runs independently",
                summary: "Approval-required autonomous work is audited and auto-decided unless a guardrail blocks it."
            ),
            activeWork: [
                WorkActiveItemDTO(
                    kind: "approval_wait",
                    status: "waiting",
                    functionId: "workspace::repair",
                    approvalId: "approval-1",
                    traceId: "trace-approval"
                ),
            ],
            workers: [
                WorkWorkerDTO(
                    workerId: "subagent:review-1",
                    label: "Review worker",
                    status: "Running",
                    health: "healthy",
                    trust: "Session worker",
                    abilityCount: 1,
                    abilities: [
                        WorkAbilityDTO(
                            functionId: "agent::spawn_subagent",
                            label: "Delegated agent work",
                            risk: "Medium",
                            effect: "ExternalSideEffect",
                            health: "Healthy"
                        ),
                    ],
                    generatedControls: [
                        WorkGeneratedControlDTO(
                            controlId: "agent-worker:review-1",
                            label: "View worker result",
                            kind: "Detail",
                            functionId: "agent::subagent_result",
                            status: "Healthy",
                            auditRef: WorkAuditRefDTO(kind: "subagent", id: "review-1", traceId: nil, catalogRevision: nil)
                        ),
                    ],
                    namespaceClaims: ["agent"],
                    workerType: "agent",
                    runId: "review-1",
                    elapsedMs: 1200,
                    auditRef: WorkAuditRefDTO(kind: "subagent", id: "review-1", traceId: nil, catalogRevision: nil)
                ),
                WorkWorkerDTO(
                    workerId: "worker-local-tools",
                    label: "Local tools",
                    status: "Ready",
                    health: "healthy",
                    trust: "Workspace trusted",
                    abilityCount: 3,
                    abilities: [
                        WorkAbilityDTO(
                            functionId: "filesystem::read_file",
                            label: "Read files",
                            risk: "Low",
                            effect: "PureRead",
                            health: "Healthy"
                        ),
                    ],
                    generatedControls: [
                        WorkGeneratedControlDTO(
                            controlId: "work-control:filesystem::read_file",
                            label: "Read files",
                            kind: "Read",
                            functionId: "filesystem::read_file",
                            status: "Healthy",
                            auditRef: nil
                        ),
                    ],
                    namespaceClaims: ["filesystem"],
                    workerType: nil,
                    runId: nil,
                    elapsedMs: nil,
                    auditRef: nil
                ),
            ],
            recentMilestones: [
                WorkMilestoneDTO(
                    kind: "invocation",
                    status: "completed",
                    functionId: "demo::echo",
                    workerId: "worker-local-tools",
                    invocationId: "inv-1",
                    traceId: "trace-1",
                    auditRef: WorkAuditRefDTO(kind: "invocation", id: "inv-1", traceId: "trace-1", catalogRevision: nil)
                ),
            ],
            guardrails: [
                WorkGuardrailDTO(
                    kind: "approval_prompt",
                    status: "blocked",
                    functionId: "workspace::repair",
                    approvalId: "approval-1",
                    traceId: "trace-approval",
                    risk: "High",
                    summary: "Testing-mode approval prompt is waiting for a decision.",
                    auditRef: WorkAuditRefDTO(kind: "approval", id: "approval-1", traceId: "trace-approval", catalogRevision: nil)
                ),
            ],
            auditRefs: [
                WorkAuditRefDTO(kind: "catalog", id: nil, traceId: nil, catalogRevision: 42),
                WorkAuditRefDTO(kind: "approval", id: "approval-1", traceId: "trace-approval", catalogRevision: nil),
                WorkAuditRefDTO(kind: "invocation", id: "inv-1", traceId: "trace-1", catalogRevision: nil),
            ],
            scope: WorkScopeDTO(sessionId: "session-1", workspaceId: "workspace-1")
        )
    }

    private static func worker(
        status: String,
        health: String,
        abilityHealth: String = "Healthy"
    ) -> WorkWorkerDTO {
        WorkWorkerDTO(
            workerId: "worker-demo",
            label: "Demo Worker",
            status: status,
            health: health,
            trust: status == "Waiting" ? "Guardrail blocked" : "Workspace trusted",
            abilityCount: 2,
            abilities: [
                WorkAbilityDTO(
                    functionId: "demo::echo",
                    label: "Echo work",
                    risk: "Low",
                    effect: "PureRead",
                    health: abilityHealth
                ),
                WorkAbilityDTO(
                    functionId: "demo::write",
                    label: "Write demo state",
                    risk: "High",
                    effect: "IrreversibleSideEffect",
                    health: abilityHealth
                ),
            ],
            generatedControls: [
                WorkGeneratedControlDTO(
                    controlId: "work-control:demo::echo",
                    label: "Echo work",
                    kind: "Read",
                    functionId: "demo::echo",
                    status: abilityHealth,
                    auditRef: nil
                ),
                WorkGeneratedControlDTO(
                    controlId: "work-control:demo::write",
                    label: "Write demo state",
                    kind: "Guarded Run",
                    functionId: "demo::write",
                    status: abilityHealth,
                    auditRef: nil
                ),
            ],
            namespaceClaims: ["demo"],
            workerType: nil,
            runId: nil,
            elapsedMs: status == "Running" ? 1200 : nil,
            auditRef: WorkAuditRefDTO(kind: "worker", id: "worker-demo", traceId: nil, catalogRevision: 42)
        )
    }

    private static func milestone(status: String) -> WorkMilestoneDTO {
        WorkMilestoneDTO(
            kind: "invocation",
            status: status,
            functionId: "demo::write",
            workerId: "worker-demo",
            invocationId: "inv-\(status)",
            traceId: "trace-\(status)",
            auditRef: WorkAuditRefDTO(kind: "invocation", id: "inv-\(status)", traceId: "trace-\(status)", catalogRevision: nil)
        )
    }

    private static func guardrail() -> WorkGuardrailDTO {
        WorkGuardrailDTO(
            kind: "approval_prompt",
            status: "blocked",
            functionId: "demo::write",
            approvalId: "approval-demo",
            traceId: "trace-approval-demo",
            risk: "High",
            summary: "Guardrail blocked Write demo state.",
            auditRef: WorkAuditRefDTO(kind: "approval", id: "approval-demo", traceId: "trace-approval-demo", catalogRevision: nil)
        )
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try projectRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
