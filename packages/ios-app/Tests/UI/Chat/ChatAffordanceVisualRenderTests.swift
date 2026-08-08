import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class ChatAffordanceVisualRenderTests: XCTestCase {
    private var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "chat-affordance-render")
        testState.registerTeardown(with: self)
    }

    override func tearDown() async throws {
        await testState.cleanup()
        testState = nil
    }

    func testApprovedChatAffordancesRenderForVisualQA() throws {
        let samples: [(String, AnyView, CGSize)] = [
            ("chat-normal.png", AnyView(Self.normalChatView), CGSize(width: 430, height: 360)),
            ("chat-response-presentation.png", AnyView(Self.responsePresentationView), CGSize(width: 430, height: 620)),
            ("chat-local-error-pill.png", AnyView(Self.localErrorView), CGSize(width: 430, height: 180)),
            ("chat-thinking-neural-spark.png", AnyView(Self.thinkingView), CGSize(width: 430, height: 180)),
            ("chat-tool-chip.png", AnyView(Self.toolChipView), CGSize(width: 430, height: 180)),
            ("chat-question-chip-states.png", AnyView(Self.questionChipStatesView), CGSize(width: 430, height: 260)),
            ("chat-connection-toast.png", AnyView(Self.connectionToastView), CGSize(width: 430, height: 180)),
            ("chat-composer-idle.png", AnyView(ComposerFixture(phase: .authoritative)), CGSize(width: 430, height: 180)),
            ("chat-composer-loading.png", AnyView(ComposerFixture(phase: .loading)), CGSize(width: 430, height: 180)),
            ("chat-composer-cached-syncing.png", AnyView(ComposerFixture(phase: .cachedSynchronizing)), CGSize(width: 430, height: 180)),
            ("sheet-loading-typography.png", AnyView(Self.sheetLoadingView), CGSize(width: 430, height: 180)),
            ("question-sheet-pending.png", AnyView(Self.pendingQuestionSheet), CGSize(width: 430, height: 700)),
            ("question-sheet-other.png", AnyView(Self.otherQuestionSheet), CGSize(width: 430, height: 700)),
            ("question-sheet-answered.png", AnyView(Self.answeredQuestionSheet), CGSize(width: 430, height: 700)),
        ]

        for (name, view, size) in samples {
            let outputURL = try render(view: view, size: size, outputName: name)
            print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
            let attachment = XCTAttachment(contentsOfFile: outputURL)
            attachment.lifetime = .keepAlways
            add(attachment)
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

    private static var responsePresentationView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ThinkingContentView(
                content: "Checking the available operation before responding.",
                isExpanded: false
            )

            StreamingContentView(text: "Streaming response text without a leading rail.")

            MessageBubble(message: ChatMessage(
                role: .assistant,
                content: .text("I will inspect that first."),
                model: "gpt-5.5",
                latencyMs: 900
            ))

            ToolInvocationChip(data: fixtureInvocation, onTap: {}, onCancel: nil)

            MessageBubble(message: ChatMessage(
                role: .assistant,
                content: .text("The final response keeps the single metadata row."),
                model: "gpt-5.5",
                latencyMs: 1_900,
                isFinalAssistantResponse: true
            ))
        }
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

    private static var toolChipView: some View {
        ToolInvocationChip(data: fixtureInvocation, onTap: {}, onCancel: nil)
            .padding(20)
            .background(Color(uiColor: .systemBackground))
    }

    private static var questionChipStatesView: some View {
        VStack(spacing: 14) {
            UserInputRequestChip(request: pendingQuestionRequest, onTap: {})
            UserInputRequestChip(request: answeredQuestionRequest, onTap: {})
        }
        .padding(20)
        .background(Color(uiColor: .systemBackground))
    }

    private static var pendingQuestionSheet: some View {
        UserInputSheet(
            request: pendingQuestionRequest,
            isAgentActive: false,
            onSubmit: { _ in }
        )
    }

    private static var answeredQuestionSheet: some View {
        UserInputSheet(
            request: answeredQuestionRequest,
            isAgentActive: false,
            onSubmit: { _ in }
        )
    }

    private static var otherQuestionSheet: some View {
        UserInputSheet(
            request: UserInputRequest(
                invocationId: "visual-other",
                questions: [questionFixtures[0]],
                answers: [
                    UserInputAnswer(
                        questionId: "color",
                        selectedLabel: nil,
                        freeText: "A custom ultraviolet accent"
                    ),
                ],
                status: .pending
            ),
            isAgentActive: false,
            onSubmit: { _ in }
        )
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

    private static var sheetLoadingView: some View {
        SheetLoadingState(label: "Loading model context…")
            .padding(24)
            .environment(\.dynamicTypeSize, .accessibility2)
            .background(Color(uiColor: .systemBackground))
    }

    private static var fixtureInvocation: ToolInvocationData {
        ToolInvocationData(
            id: "visual-tool",
            status: .running,
            arguments: #"{"file":"README.md","intent":"Read project overview"}"#,
            progressMessage: "Reading",
            identity: ToolIdentity(
                toolName: "file_read",
                traceId: "trace-visual"
            )
        )
    }

    private static var pendingQuestionRequest: UserInputRequest {
        UserInputRequest(
            invocationId: "visual-question",
            questions: questionFixtures,
            answers: [],
            status: .pending
        )
    }

    private static var answeredQuestionRequest: UserInputRequest {
        UserInputRequest(
            invocationId: "visual-question",
            questions: questionFixtures,
            answers: [
                UserInputAnswer(questionId: "color", selectedLabel: "Green", freeText: nil),
                UserInputAnswer(questionId: "format", selectedLabel: nil, freeText: "A concise brief"),
                UserInputAnswer(questionId: "priority", selectedLabel: "Accuracy", freeText: nil),
            ],
            status: .answered
        )
    }

    private static var questionFixtures: [UserInputQuestion] {
        [
            UserInputQuestion(
                header: "Color",
                id: "color",
                question: "Which color do you prefer?",
                options: [
                    UserInputOption(label: "Blue", description: "Use a cool blue accent."),
                    UserInputOption(label: "Green", description: "Use Tron's green accent."),
                    UserInputOption(label: "Amber", description: "Use a warm amber accent."),
                ]
            ),
            UserInputQuestion(
                header: "Format",
                id: "format",
                question: "How detailed should the response be?",
                options: [
                    UserInputOption(label: "Concise", description: "Keep the response brief."),
                    UserInputOption(label: "Detailed", description: "Include explanation and context."),
                ]
            ),
            UserInputQuestion(
                header: "Priority",
                id: "priority",
                question: "What should be prioritized?",
                options: [
                    UserInputOption(label: "Speed", description: "Complete the task quickly."),
                    UserInputOption(label: "Accuracy", description: "Optimize for careful results."),
                ]
            ),
        ]
    }

    private struct ComposerFixture: View {
        let phase: ConversationHistoryPhase
        @State private var state = InputBarState()

        var body: some View {
            VStack {
                Spacer()
                InputBar(
                    state: state,
                    config: InputBarConfig(
                        speechTranscriptionAvailable: true,
                        placeholderText: phase.placeholderText,
                        placeholderShowsProgress: phase.placeholderShowsProgress,
                        contextPercentage: 68,
                        currentModelInfo: nil,
                        readOnly: false,
                        allowsTextEntry: phase.allowsLocalDraftActions,
                        allowsAttachments: phase.allowsLocalDraftActions,
                        allowsSpeechCapture: phase.allowsLocalDraftActions,
                        allowsSubmission: phase.hasAuthoritativeSnapshot,
                        availabilityBlockReason: phase.submissionBlockReason
                    ),
                    actions: InputBarActions(onContextTap: {})
                )
            }
            .padding(.bottom, 20)
            .background(Color(uiColor: .systemBackground))
        }
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
        try testState.artifactURL(named: outputName)
    }
}
