import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class WorkspaceSelectorVisualRenderTests: XCTestCase {
    func testWorkspaceSelectorNavigationHierarchyRendersForVisualQA() throws {
        var selectedPath = "/tmp/tron-fixtures/home"
        let view = WorkspaceSelector(
            selectedPath: Binding(
                get: { selectedPath },
                set: { selectedPath = $0 }
            ),
            options: [
                WorkspaceSelectionOption(
                    path: "/tmp/tron-fixtures/home/Workspace",
                    title: "Default workspace",
                    subtitle: "~/Workspace",
                    source: .defaultWorkspace
                ),
            ],
            connectionRepository: WorkspaceSelectorVisualConnectionRepository(),
            workspaceBrowserRepository: WorkspaceSelectorVisualBrowserRepository()
        )

        let outputURL = try render(
            view: AnyView(view),
            size: CGSize(width: 430, height: 920),
            outputName: "workspace-selector-navigation.png"
        )
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    private func render(view: AnyView, size: CGSize, outputName: String) throws -> URL {
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
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
        return outputURL
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
}

@MainActor
private final class WorkspaceSelectorVisualConnectionRepository: AppConnectionRepository {
    var connectionState: ConnectionState { .connected }
    var isConnected: Bool { true }

    func connect() async {}
    func disconnect() async {}
    func verifyConnection() async -> Bool { true }
    func manualRetry() async {}
    func setBackgroundState(_ inBackground: Bool) {}
}

@MainActor
private final class WorkspaceSelectorVisualBrowserRepository: WorkspaceBrowserRepository {
    private let homePath = "/tmp/tron-fixtures/home"

    func getHome() async throws -> WorkspaceHomeResult {
        WorkspaceHomeResult(
            homePath: homePath,
            suggestedPaths: [
                WorkspaceSuggestedPath(name: "Desktop", path: "\(homePath)/Desktop", exists: true),
                WorkspaceSuggestedPath(name: "Documents", path: "\(homePath)/Documents", exists: true),
            ]
        )
    }

    func listDirectory(path: String?, showHidden: Bool) async throws -> WorkspaceDirectoryListResult {
        let current = path ?? homePath
        var entries = [
            directory("Applications", at: "\(homePath)/Applications"),
            directory("Archives", at: "\(homePath)/Archives"),
            directory("Desktop", at: "\(homePath)/Desktop"),
            directory("Documents", at: "\(homePath)/Documents"),
            directory("Downloads", at: "\(homePath)/Downloads"),
            directory("Library", at: "\(homePath)/Library"),
        ]
        if showHidden {
            entries.insert(directory(".config", at: "\(homePath)/.config"), at: 0)
        }
        return WorkspaceDirectoryListResult(
            path: current,
            parent: "/tmp/tron-fixtures",
            entries: entries,
            truncated: false
        )
    }

    func createDirectory(
        path: String,
        recursive: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkspaceCreateDirectoryResult {
        WorkspaceCreateDirectoryResult(created: true, path: path)
    }

    private func directory(_ name: String, at path: String) -> WorkspaceDirectoryEntry {
        WorkspaceDirectoryEntry(
            name: name,
            path: path,
            isDirectory: true,
            isSymlink: false,
            size: nil,
            modifiedAt: nil
        )
    }
}
