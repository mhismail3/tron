import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class ChatAffordanceVisualRenderTests: XCTestCase {
    func testApprovedChatAffordancesRenderForVisualQA() throws {
        let samples: [(String, AnyView, CGSize)] = [
            ("chat-normal.png", AnyView(Self.normalChatView), CGSize(width: 430, height: 360)),
            ("chat-empty.png", AnyView(Self.auxiliaryView(ChatTimelineEmptyView(title: "Start talking"))), CGSize(width: 430, height: 320)),
            ("chat-loading.png", AnyView(Self.auxiliaryView(ChatTimelineLoadingView(title: "Loading messages"))), CGSize(width: 430, height: 320)),
            ("chat-local-error-pill.png", AnyView(Self.localErrorView), CGSize(width: 430, height: 180)),
            ("chat-thinking-neural-spark.png", AnyView(Self.thinkingView), CGSize(width: 430, height: 180)),
            ("chat-capability-chip.png", AnyView(Self.capabilityChipView), CGSize(width: 430, height: 180)),
            ("chat-connection-toast.png", AnyView(Self.connectionToastView), CGSize(width: 430, height: 180)),
        ]

        for (name, view, size) in samples {
            let outputURL = try render(view: view, size: size, outputName: name)
            print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
            add(XCTAttachment(contentsOfFile: outputURL))
        }
    }

    private static var normalChatView: some View {
        VStack(spacing: 16) {
            MessageBubble(message: ChatMessage(role: .user, content: .text("Can you check the workspace status?")))
            MessageBubble(message: ChatMessage(role: .assistant, content: .text("The workspace is clean.")))
        }
        .padding(20)
        .background(Color(uiColor: .systemBackground))
    }

    private static func auxiliaryView(_ content: some View) -> some View {
        content
            .padding(20)
            .background(Color(uiColor: .systemBackground))
    }

    private static var localErrorView: some View {
        LocalChatNotificationView(
            notification: LocalChatNotification.error(
                dedupKey: "visual.error",
                title: "Could not attach file",
                message: "The file could not be read.",
                suggestion: "Try again or choose a different file."
            ),
            onDetails: { _ in }
        )
        .padding(20)
        .background(Color(uiColor: .systemBackground))
    }

    private static var thinkingView: some View {
        HStack {
            AnimatedThinkingLine()
            Spacer()
        }
        .padding(20)
        .background(Color(uiColor: .systemBackground))
    }

    private static var capabilityChipView: some View {
        CapabilityInvocationChip(data: fixtureInvocation, onTap: {}, onCancel: nil)
            .padding(20)
            .background(Color(uiColor: .systemBackground))
    }

    private static var connectionToastView: some View {
        let toastCenter = ToastCenter()
        toastCenter.push(
            "Reconnecting to server",
            severity: .warning,
            dedupKey: "visual.connection",
            autoDismiss: .sticky
        )
        return ToastBannerStack(toastCenter: toastCenter)
            .padding(.top, 20)
            .background(Color(uiColor: .systemBackground))
    }

    private static var fixtureInvocation: CapabilityInvocationData {
        CapabilityInvocationData(
            id: "visual-capability",
            status: .running,
            arguments: #"{"file":"README.md","intent":"Read project overview"}"#,
            progressMessage: "Reading",
            identity: CapabilityIdentity(
                modelPrimitiveName: "file_read",
                operationName: "file_read",
                traceId: "trace-visual"
            )
        )
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
