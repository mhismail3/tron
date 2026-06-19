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

    func testWorkspaceSelectionOptionsIncludeDefaultThenRecentWorkspaces() {
        let options = WorkspaceSelectionOptionBuilder.options(
            defaultWorkspace: "  /tmp/tron-fixtures/default  ",
            recentWorkspaces: [
                (path: "/tmp/tron-fixtures/recent-a", name: "recent-a"),
                (path: "/tmp/tron-fixtures/recent-b", name: "recent-b"),
            ]
        )

        XCTAssertEqual(options.map(\.path), [
            "/tmp/tron-fixtures/default",
            "/tmp/tron-fixtures/recent-a",
            "/tmp/tron-fixtures/recent-b",
        ])
        XCTAssertEqual(options.map(\.source), [.defaultWorkspace, .recent, .recent])
        XCTAssertEqual(options[0].title, "Default workspace")
        XCTAssertEqual(options[1].title, "recent-a")
    }

    func testWorkspaceSelectionOptionsDeduplicateDefaultAndRecentWorkspaces() {
        let options = WorkspaceSelectionOptionBuilder.options(
            defaultWorkspace: "/tmp/tron-fixtures/project",
            recentWorkspaces: [
                (path: "/tmp/tron-fixtures/project", name: "project"),
                (path: "  /tmp/tron-fixtures/other  ", name: ""),
                (path: "/tmp/tron-fixtures/other", name: "other"),
                (path: " ", name: "blank"),
            ]
        )

        XCTAssertEqual(options.map(\.path), [
            "/tmp/tron-fixtures/project",
            "/tmp/tron-fixtures/other",
        ])
        XCTAssertEqual(options[1].title, "other")
    }

    func testWorkspaceSelectorStaysLocalSuggestionPlusManualPath() throws {
        let combined = try [
            "Sources/UI/Chat/Sheets/NewSessionFlow.swift",
            "Sources/UI/Chat/Sheets/NewSessionFlowTypes.swift",
            "Sources/UI/Chat/Sheets/WorkspaceSelector.swift",
            "Sources/UI/Chat/Shell/ContentView.swift",
        ].map { relativePath in
            try String(
                contentsOf: iosAppRoot().appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        for fragment in [
            "WorkspaceSelectionOptionBuilder.options(",
            "defaultWorkspace: dependencies.quickSessionWorkspace",
            "options: workspaceSelectionOptions",
            "Text(\"Suggested\")",
            "Text(\"Manual path\")",
        ] {
            XCTAssertTrue(
                combined.contains(fragment),
                "new-session workspace selector missing current local suggestion marker: \(fragment)"
            )
        }

        for fragment in [
            "Engine" + "Client",
            "Filesystem" + "Client",
            "." + "filesystem",
            "get" + "Home(",
            "list" + "Directory(",
            "create" + "Directory(",
            "Directory" + "Entry",
            "New" + " Folder",
            "show" + "Hidden",
            "Folder" + "Name" + "Validator",
        ] {
            XCTAssertFalse(
                combined.contains(fragment),
                "new-session workspace selector must not restore the old filesystem browser surface: \(fragment)"
            )
        }
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

    private func iosAppRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
