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
        let source = try source(pathComponents: ["Sources", "UI", "Tools", "ToolInvocationViews.swift"])

        XCTAssertTrue(source.contains("ToolEvidencePresentation(data: data)"))
        XCTAssertTrue(source.contains("ToolInvocationBriefPresentation(data: data)"))
        XCTAssertTrue(source.contains("ToolRowsDetailLink"))
        XCTAssertTrue(source.contains("ToolRawDetailLink"))
        XCTAssertTrue(source.contains("ToolRowsDetailSheet"))
        XCTAssertFalse(source.contains("DisclosureGroup"))
        XCTAssertFalse(source.contains("ForEach(evidence.sections)"))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Target""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Action""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Runtime Details""#))
        XCTAssertFalse(source.contains(#"ToolDetailSection(title: "Advanced""#))
        XCTAssertFalse(source.contains("Approval state"))
    }

    func testToolDetailSectionUsesLiquidGlassSurfaceForStableDetailNavigation() throws {
        let source = try source(pathComponents: ["Sources", "UI", "Tools", "Shared", "ToolDetailSection.swift"])

        XCTAssertTrue(source.contains(".sectionFill(accent"))
        XCTAssertTrue(source.contains("payload or evidence detail opens in nested sheets"))
        XCTAssertFalse(source.contains("Color.tronSurface.opacity(0.86)"))
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
                traceId: "trace-process"
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

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
