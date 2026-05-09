import XCTest
@testable import TronMobile

final class NewSessionFlowTests: XCTestCase {
    private func makeModel(
        id: String,
        name: String,
        provider: String,
        tier: String,
        recommended: Bool? = nil,
        available: Bool? = true
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            name: name,
            provider: provider,
            contextWindow: 128_000,
            supportsThinking: false,
            supportsImages: false,
            supportsDocuments: false,
            tier: tier,
            isRetiredGeneration: false,
            recommended: recommended,
            available: available
        )
    }

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
        XCTAssertEqual(intent?.profile, "chat")
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
        XCTAssertEqual(isolated?.profile, "normal")
        XCTAssertEqual(isolated?.useWorktree, true)
        XCTAssertEqual(passthrough?.useWorktree, false)
        XCTAssertNil(NewSessionCreateIntent.project(
            workingDirectory: "",
            model: "claude-sonnet-4-6",
            useWorktreeOverride: nil
        ))
    }

    func testQuickChatWithoutWorkspaceSelectsWorkspace() {
        let action = NewSessionQuickChatPresetAction.resolve(
            quickWorkspace: ""
        )

        XCTAssertEqual(action, .selectWorkspace)
    }

    func testQuickChatWithWorkspaceConfiguresTheSheet() {
        let action = NewSessionQuickChatPresetAction.resolve(
            quickWorkspace: "/tmp/tron-recent"
        )

        XCTAssertEqual(action, .configure(workspace: "/tmp/tron-recent"))
    }

    func testQuickChatWithWorkspaceConfiguresEvenBeforeModelSelection() {
        let action = NewSessionQuickChatPresetAction.resolve(
            quickWorkspace: "/tmp/tron-recent"
        )

        XCTAssertEqual(action, .configure(workspace: "/tmp/tron-recent"))
    }

    func testLocalModelForcesLocalProfileMode() {
        let local = makeModel(
            id: "llama3.2",
            name: "Llama 3.2",
            provider: "ollama",
            tier: "local"
        )

        XCTAssertEqual(NewSessionProfileMode.effective(requested: .normal, selectedModel: local), .local)
        XCTAssertEqual(NewSessionProfileMode.effective(requested: .chat, selectedModel: local), .local)
    }

    func testCloudModelPreservesRequestedProfileMode() {
        let cloud = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet"
        )

        XCTAssertEqual(NewSessionProfileMode.effective(requested: .normal, selectedModel: cloud), .normal)
        XCTAssertEqual(NewSessionProfileMode.effective(requested: .chat, selectedModel: cloud), .chat)
    }

    func testProjectIntentCarriesLocalProfile() {
        let intent = NewSessionCreateIntent.project(
            workingDirectory: "/tmp/tron-project",
            model: "llama3.2",
            profile: .local,
            useWorktreeOverride: nil
        )

        XCTAssertEqual(intent?.profile, "local")
        XCTAssertNil(intent?.source)
    }

    func testPreferredModelUsesLocalModelForLocalProfile() {
        let cloud = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet",
            recommended: true
        )
        let local = makeModel(
            id: "llama3.2",
            name: "Llama 3.2",
            provider: "ollama",
            tier: "local",
            recommended: true
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: cloud.id,
                availableModels: [cloud, local],
                profile: .local
            ),
            local.id
        )
    }

    func testPreferredModelKeepsDefaultCloudModelForMainAndChatProfiles() {
        let cloud = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet",
            recommended: true
        )
        let local = makeModel(
            id: "llama3.2",
            name: "Llama 3.2",
            provider: "ollama",
            tier: "local",
            recommended: true
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: cloud.id,
                availableModels: [local, cloud],
                profile: .normal
            ),
            cloud.id
        )
        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: cloud.id,
                availableModels: [local, cloud],
                profile: .chat
            ),
            cloud.id
        )
    }

    func testPreferredModelSwitchesAwayFromLocalModelForNonLocalProfiles() {
        let local = makeModel(
            id: "llama3.2",
            name: "Llama 3.2",
            provider: "ollama",
            tier: "local",
            recommended: true
        )
        let cloud = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet",
            recommended: true
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: local.id,
                availableModels: [local, cloud],
                profile: .normal
            ),
            cloud.id
        )
        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: local.id,
                availableModels: [local, cloud],
                profile: .chat
            ),
            cloud.id
        )
    }

    func testPreferredModelDoesNotUseOnlyLocalModelForNonLocalProfiles() {
        let local = makeModel(
            id: "llama3.2",
            name: "Llama 3.2",
            provider: "ollama",
            tier: "local",
            recommended: true
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: local.id,
                availableModels: [local],
                profile: .normal
            ),
            ""
        )
    }

    func testPreferredModelDoesNotPickKnownUnavailableLocalModel() {
        let cloud = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet",
            recommended: true
        )
        let unavailableLocal = makeModel(
            id: "llama3.2",
            name: "Llama 3.2",
            provider: "ollama",
            tier: "local",
            recommended: true,
            available: false
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: unavailableLocal.id,
                availableModels: [unavailableLocal, cloud],
                profile: .normal
            ),
            cloud.id
        )
        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: unavailableLocal.id,
                availableModels: [unavailableLocal, cloud],
                profile: .local
            ),
            ""
        )
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
            isRetiredGeneration: false
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
