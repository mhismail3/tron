import SwiftUI
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

    func testNewSessionFlowUsesLargeInitialPresentation() {
        XCTAssertEqual(NewSessionFlowPresentation.detents, [.large])
    }

    func testCreateIntentRequiresWorkspaceAndModel() {
        XCTAssertNil(NewSessionCreateIntent.make(workingDirectory: "", model: "claude-sonnet-4-6"))
        XCTAssertNil(NewSessionCreateIntent.make(workingDirectory: "/tmp/tron", model: ""))
    }

    func testCreateIntentTrimsPrimitiveInputs() {
        let intent = NewSessionCreateIntent.make(
            workingDirectory: "  /tmp/tron-project  ",
            model: "  claude-sonnet-4-6  "
        )

        XCTAssertEqual(intent?.workingDirectory, "/tmp/tron-project")
        XCTAssertEqual(intent?.model, "claude-sonnet-4-6")
    }

    func testPreferredModelKeepsAvailableDefaultModel() {
        let defaultModel = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet"
        )
        let recommended = makeModel(
            id: "gpt-5.1",
            name: "GPT 5.1",
            provider: "openai",
            tier: "frontier",
            recommended: true
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: defaultModel.id,
                availableModels: [recommended, defaultModel]
            ),
            defaultModel.id
        )
    }

    func testPreferredModelUsesRecommendedModelWhenDefaultIsEmpty() {
        let first = makeModel(
            id: "claude-haiku-4-6",
            name: "Haiku 4.6",
            provider: "anthropic",
            tier: "haiku"
        )
        let recommended = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet",
            recommended: true
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: "",
                availableModels: [first, recommended]
            ),
            recommended.id
        )
    }

    func testPreferredModelKeepsUnknownDefaultUntilServerModelsArrive() {
        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: "custom-provider-model",
                availableModels: []
            ),
            "custom-provider-model"
        )
    }

    func testPreferredModelSkipsUnavailableModels() {
        let unavailable = makeModel(
            id: "claude-sonnet-4-6",
            name: "Sonnet 4.6",
            provider: "anthropic",
            tier: "sonnet",
            recommended: true,
            available: false
        )
        let available = makeModel(
            id: "gpt-5.1",
            name: "GPT 5.1",
            provider: "openai",
            tier: "frontier"
        )

        XCTAssertEqual(
            NewSessionPreferredModel.resolve(
                defaultModel: unavailable.id,
                availableModels: [unavailable, available]
            ),
            available.id
        )
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
}
