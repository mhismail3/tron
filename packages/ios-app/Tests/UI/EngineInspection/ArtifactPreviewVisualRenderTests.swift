import CryptoKit
import SwiftUI
import XCTest

@testable import TronMobile

@MainActor
final class ArtifactPreviewVisualRenderTests: XCTestCase {
    private var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "artifact-preview-render")
        testState.registerTeardown(with: self)
    }

    override func tearDown() async throws {
        await testState.cleanup()
        testState = nil
    }

    func testMarkdownPreviewSheetRendersForVisualQA() async throws {
        let data = Data(Self.markdown.utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let artifact = WorkerArtifactDTO(
            workerId: "document-artifact",
            artifactId: "visual-report",
            displayName: "worker-evaluation-report.md",
            mediaType: "text/markdown",
            sizeBytes: UInt64(data.count),
            contentSha256: "sha256:\(digest)",
            contentReference: WorkerArtifactContentReferenceDTO(
                kind: "artifact_content_reference",
                workerId: "document-artifact",
                artifactId: "visual-report",
                contentSha256: "sha256:\(digest)",
                sizeBytes: UInt64(data.count)
            ),
            sourceInvocationId: "worker-run-visual",
            sourceWorkerVersion: "v1",
            traceId: "trace-visual",
            createdAt: "2026-08-07T00:00:00Z"
        )
        let repository = ArtifactRepositoryStub(
            page: WorkerArtifactPageDTO(
                artifacts: [artifact],
                returned: 1,
                total: 1,
                nextOffset: nil,
                storageAttention: WorkerArtifactStorageAttentionDTO(
                    state: "normal",
                    artifactBytes: UInt64(data.count),
                    databaseBytes: UInt64(data.count),
                    databaseBudgetBytes: 536_870_912,
                    overBudget: false,
                    message: nil
                )
            ),
            content: WorkerArtifactContentDTO(
                artifact: artifact,
                data: data.base64EncodedString()
            )
        )
        let files = WorkerArtifactFileCoordinator(
            rootURL: testState.rootURL.appendingPathComponent(
                "artifact-previews",
                isDirectory: true
            )
        )
        let viewModel = ArtifactInboxViewModel(files: files)
        await viewModel.load(artifact, repository: repository)
        XCTAssertNotNil(viewModel.materialized[artifact.id])

        let view = ArtifactPreviewSheet(
            artifact: artifact,
            repository: repository,
            viewModel: viewModel,
            continuity: EngineConnectionContinuity(
                state: .connected,
                generation: 1
            ),
            onDeleted: {}
        )
        let outputURL = try render(
            view: AnyView(view),
            size: CGSize(width: 430, height: 820),
            outputName: "artifact-markdown-preview.png"
        )

        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        let attachment = XCTAttachment(contentsOfFile: outputURL)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func render(
        view: AnyView,
        size: CGSize,
        outputName: String
    ) throws -> URL {
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap {
                $0 as? UIWindowScene
            }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color(uiColor: .systemBackground))
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let image = UIGraphicsImageRenderer(
            bounds: controller.view.bounds,
            format: format
        ).image { _ in
            controller.view.drawHierarchy(
                in: controller.view.bounds,
                afterScreenUpdates: true
            )
        }
        XCTAssertEqual(image.size, size)

        let outputURL = try testState.artifactURL(named: outputName)
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        return outputURL
    }

    private static let markdown = """
    # Worker evaluation report

    Suite: `tron-worker-baseline`

    - Passed: 6
    - Failed: 0
    - Grounding: verified

    ## Summary

    The worker completed every deterministic and semantic evaluation case.
    Citations resolved to the recorded evidence and no regressions were found.
    """
}
