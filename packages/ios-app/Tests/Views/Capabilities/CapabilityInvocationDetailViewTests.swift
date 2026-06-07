import SwiftUI
import XCTest
@testable import TronMobile

@available(iOS 26.0, *)
@MainActor
final class CapabilityInvocationDetailViewTests: XCTestCase {
    func testCapabilityInvocationDetailSourceKeepsRawProtocolDataAuditOnly() throws {
        let source = try source(pathComponents: ["Sources", "Views", "Capabilities", "CapabilityInvocationViews.swift"])

        XCTAssertTrue(source.contains(#"CapabilityDetailSection(title: "Action""#))
        XCTAssertTrue(source.contains(#"CapabilityDetailSection(title: "Runtime Details""#))
        XCTAssertTrue(source.contains(#"CapabilityRawDisclosure(title: "Raw request""#))
        XCTAssertTrue(source.contains(#"CapabilityRawDisclosure(title: "Raw result""#))
        XCTAssertFalse(source.contains(#"CapabilityDetailSection(title: "Request""#))
        XCTAssertFalse(source.contains(#"CapabilityDetailSection(title: "Advanced""#))
        XCTAssertFalse(source.contains("Approval state"))
    }

    func testCapabilityDetailSectionUsesSolidSurfaceForPayloadReadability() throws {
        let source = try source(pathComponents: ["Sources", "Views", "Capabilities", "Shared", "CapabilityDetailSection.swift"])

        XCTAssertTrue(source.contains("Color.tronSurface.opacity"))
        XCTAssertTrue(source.contains(".stroke(accent.opacity"))
        XCTAssertFalse(source.contains(".glassEffect("))
    }

    func testCapabilityInvocationDetailRendersActionFirstSummaryForVisualQA() throws {
        let size = CGSize(width: 430, height: 932)
        let view = CapabilityInvocationDetailSheet(data: Self.fixtureInvocation)
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

        let outputURL = try visualArtifactURL(outputName: "capability-invocation-detail-action-render.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    private static var fixtureInvocation: CapabilityInvocationData {
        CapabilityInvocationData(
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
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "process_run",
                traceId: "trace-process"
            )
        )
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
