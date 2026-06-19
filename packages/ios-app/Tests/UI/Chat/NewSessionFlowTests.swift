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

    func testWorkspaceSelectorUsesServerBackedBrowserWithLocalQuickPaths() throws {
        let combined = try [
            "Sources/UI/Chat/Sheets/NewSessionFlow.swift",
            "Sources/UI/Chat/Sheets/NewSessionFlowTypes.swift",
            "Sources/UI/Chat/Sheets/WorkspaceSelector.swift",
            "Sources/UI/Chat/Shell/ContentView.swift",
            "Sources/Engine/Transport/Clients/WorkspaceBrowserClient.swift",
            "Sources/Engine/Protocol/Filesystem/EngineProtocolTypes+Filesystem.swift",
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
            "workspaceBrowserRepository: dependencies.workspaceBrowserRepository",
            "WorkspaceBrowserClient",
            "WorkspaceBrowserRepository",
            "filesystem::get_home",
            "filesystem::list_dir",
            "filesystem::create_dir",
            "showHidden",
            "New Folder",
            "FolderNameValidator",
            "Workspace browser is not available on this server",
        ] {
            XCTAssertTrue(
                combined.contains(fragment),
                "workspace selector missing restored browser marker: \(fragment)"
            )
        }

        for fragment in [
            "read_file",
            "write_file",
            "edit_file",
            "search_text",
            "apply_patch",
            "Sources/Engine/Network/Clients/" + "Filesystem" + "Client.swift",
            "Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Filesystem.swift",
        ] {
            XCTAssertFalse(
                combined.contains(fragment),
                "workspace selector restored a broad legacy filesystem surface: \(fragment)"
            )
        }
    }

    func testFolderNameValidatorAllowsHiddenFoldersButRejectsPathSegments() {
        XCTAssertNil(FolderNameValidator.validationError(for: "Project"))
        XCTAssertNil(FolderNameValidator.validationError(for: ".config"))
        XCTAssertEqual(
            FolderNameValidator.validationError(for: " "),
            "Folder name cannot be empty"
        )
        XCTAssertEqual(
            FolderNameValidator.validationError(for: ".."),
            "Folder name cannot be .."
        )
        XCTAssertEqual(
            FolderNameValidator.validationError(for: "parent/child"),
            "Folder name cannot contain /"
        )
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
