import XCTest
@testable import TronMobile

final class NewSessionFlowTests: XCTestCase {

    func testChatIntentUsesChatSourceAndNoWorktreeOverride() {
        let intent = NewSessionCreateIntent.chat(
            workspace: "/tmp/tron-chat-workspace",
            model: "claude-sonnet-4-6"
        )

        XCTAssertEqual(intent?.kind, .chat)
        XCTAssertEqual(intent?.workingDirectory, "/tmp/tron-chat-workspace")
        XCTAssertEqual(intent?.model, "claude-sonnet-4-6")
        XCTAssertEqual(intent?.title, "Chat")
        XCTAssertEqual(intent?.source, "chat")
        XCTAssertNil(intent?.useWorktree)
    }

    func testChatIntentRequiresWorkspaceAndModel() {
        XCTAssertNil(NewSessionCreateIntent.chat(workspace: "", model: "claude-sonnet-4-6"))
        XCTAssertNil(NewSessionCreateIntent.chat(workspace: "/tmp/tron-chat-workspace", model: ""))
    }

    func testProjectIntentRequiresWorkspaceAndCarriesWorktreeOverride() {
        let isolated = NewSessionCreateIntent.project(
            workingDirectory: "/tmp/tron-project",
            model: "claude-sonnet-4-6",
            useWorktreeOverride: true
        )
        let passthrough = NewSessionCreateIntent.project(
            workingDirectory: "/tmp/tron-project",
            model: "claude-sonnet-4-6",
            useWorktreeOverride: false
        )

        XCTAssertEqual(isolated?.kind, .project)
        XCTAssertEqual(isolated?.workingDirectory, "/tmp/tron-project")
        XCTAssertEqual(isolated?.model, "claude-sonnet-4-6")
        XCTAssertNil(isolated?.title)
        XCTAssertNil(isolated?.source)
        XCTAssertEqual(isolated?.useWorktree, true)
        XCTAssertEqual(passthrough?.useWorktree, false)
        XCTAssertNil(NewSessionCreateIntent.project(
            workingDirectory: "",
            model: "claude-sonnet-4-6",
            useWorktreeOverride: nil
        ))
    }

    func testQuickChatWithoutWorkspaceSelectsWorkspace() {
        let action = NewSessionChatStartAction.resolve(
            quickWorkspace: "",
            model: "claude-sonnet-4-6"
        )

        XCTAssertEqual(action, .selectWorkspace)
    }

    func testQuickChatWithWorkspaceCreatesChatIntent() {
        let action = NewSessionChatStartAction.resolve(
            quickWorkspace: "/tmp/tron-recent",
            model: "claude-sonnet-4-6"
        )

        XCTAssertEqual(action, .create(NewSessionCreateIntent(
            kind: .chat,
            workingDirectory: "/tmp/tron-recent",
            model: "claude-sonnet-4-6",
            title: "Chat",
            source: "chat",
            useWorktree: nil
        )))
    }

    func testQuickChatWithWorkspaceWaitsForModel() {
        let action = NewSessionChatStartAction.resolve(
            quickWorkspace: "/tmp/tron-recent",
            model: ""
        )

        XCTAssertEqual(action, .waitForModel)
    }

    func testCloneTargetUsesSelectedWorkspace() {
        XCTAssertEqual(
            NewSessionCloneTarget.destinationWorkspace(from: "  /tmp/tron-parent  "),
            "/tmp/tron-parent"
        )
    }

    func testCloneTargetRequiresSelectedWorkspace() {
        XCTAssertNil(NewSessionCloneTarget.destinationWorkspace(from: ""))
        XCTAssertNil(NewSessionCloneTarget.destinationWorkspace(from: "   "))
    }

    func testModelCardValueUsesServerShortName() {
        let model = ModelInfo(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            contextWindow: 200_000,
            supportsThinking: true,
            supportsImages: true,
            supportsDocuments: true,
            tier: "sonnet",
            isLegacy: false
        )

        XCTAssertEqual(
            NewSessionModelCardValue.resolve(
                selectedModel: "claude-sonnet-4-6",
                availableModels: [model],
                isLoadingModels: false
            ),
            "Sonnet 4.6"
        )
    }

    func testModelCardValueFallsBackToParsedShortName() {
        XCTAssertEqual(
            NewSessionModelCardValue.resolve(
                selectedModel: "claude-opus-4-6",
                availableModels: [],
                isLoadingModels: false
            ),
            "Opus 4.6"
        )
    }

    func testWorktreeVisibilityStaysVisibleWhileCheckingWorkspaceSwitch() {
        XCTAssertTrue(NewSessionWorktreeVisibility.whileChecking(
            currentIsGitRepo: true,
            nextWorkspace: "/tmp/next-workspace"
        ))
    }

    func testWorktreeVisibilityDoesNotAppearWhileCheckingFromHiddenState() {
        XCTAssertFalse(NewSessionWorktreeVisibility.whileChecking(
            currentIsGitRepo: false,
            nextWorkspace: "/tmp/next-workspace"
        ))
    }

    func testWorktreeVisibilityHidesImmediatelyForEmptyWorkspace() {
        XCTAssertFalse(NewSessionWorktreeVisibility.whileChecking(
            currentIsGitRepo: true,
            nextWorkspace: "   "
        ))
    }
}
