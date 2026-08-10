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

    func testNewSessionFlowStartsAtMediumPresentation() {
        XCTAssertEqual(NewSessionFlowPresentation.detents, [.medium, .large])
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
        XCTAssertNil(intent?.sourceControl)
    }

    func testCreateIntentCarriesOnlyTheClosedSourceControlSelection() {
        let sourceControl = SessionSourceControlSelection(placement: .worktree)
        let intent = NewSessionCreateIntent.make(
            workingDirectory: "/tmp/tron-project",
            model: "gpt-5.6-sol",
            sourceControl: sourceControl
        )

        XCTAssertEqual(intent?.sourceControl, sourceControl)
    }

    func testSourceControlPlacementPresentationExplainsAllThreeModes() {
        XCTAssertEqual(SessionSourceControlPlacement.existing.title, "Use Existing")
        XCTAssertEqual(SessionSourceControlPlacement.branch.title, "New Branch")
        XCTAssertEqual(SessionSourceControlPlacement.worktree.title, "New Worktree")
        XCTAssertTrue(
            SessionSourceControlPlacement.existing.caption(currentBranch: "main")
                .contains("main")
        )
        XCTAssertTrue(
            SessionSourceControlPlacement.branch.caption(currentBranch: "main")
                .contains("switch")
        )
        XCTAssertTrue(
            SessionSourceControlPlacement.worktree.caption(currentBranch: "main")
                .contains("isolated")
        )
    }

    func testAuthoritativeCheckoutPathIsRequiredForGitPlacement() {
        let worktree = SessionSourceControlSelection(placement: .worktree)
        XCTAssertNil(NewSessionWorkingDirectoryResolution.resolve(
            requested: "/tmp/project",
            sourceControl: worktree,
            serverWorkingDirectory: nil
        ))
        XCTAssertEqual(NewSessionWorkingDirectoryResolution.resolve(
            requested: "/tmp/project",
            sourceControl: worktree,
            serverWorkingDirectory: " /tmp/session-worktree "
        ), "/tmp/session-worktree")
        XCTAssertEqual(NewSessionWorkingDirectoryResolution.resolve(
            requested: "/tmp/project",
            sourceControl: nil,
            serverWorkingDirectory: nil
        ), "/tmp/project")
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
            "Sources/UI/Chat/Sheets/WorkspaceSelectorRows.swift",
            "Sources/UI/Chat/Shell/ContentView.swift",
            "Sources/Engine/Transport/Clients/WorkspaceBrowserClient.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Filesystem.swift",
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
            "filesystem::inspect_source_control",
            "showHidden",
            "Shortcuts",
            "Current folder",
            "Folders",
            "New Folder",
            "Hidden",
            "FolderNameValidator",
            "WorkspaceQuickPathPill",
            "WorkspaceDirectoryActionPill",
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
                "workspace selector exposed a broad filesystem surface: \(fragment)"
            )
        }
    }

    func testGitPlacementIsConditionalAndPrecedesModelSelection() throws {
        let source = try String(
            contentsOf: iosAppRoot()
                .appendingPathComponent("Sources/UI/Chat/Sheets/NewSessionFlow.swift"),
            encoding: .utf8
        )
        let workspace = try XCTUnwrap(source.range(of: "title: \"Workspace\""))
        let sourceControl = try XCTUnwrap(source.range(of: "title: \"Source Control\""))
        let model = try XCTUnwrap(source.range(of: "title: \"Model\""))

        XCTAssertLessThan(workspace.lowerBound, sourceControl.lowerBound)
        XCTAssertLessThan(sourceControl.lowerBound, model.lowerBound)
        XCTAssertTrue(source.contains("sourceControlProjection.presentedGitStatus"))
        XCTAssertTrue(source.contains("selectedSourceControlStatus?.isGitRepository == true"))
        XCTAssertTrue(source.contains(".task(id: NewSessionSourceControlProbeKey("))
        XCTAssertFalse(source.contains(".onChange(of: workingDirectory)"))
        XCTAssertTrue(source.contains("sourceControl: intent.sourceControl"))
        XCTAssertTrue(source.contains("serverWorkingDirectory: result.workingDirectory"))
    }

    func testSourceControlStatusDecodesTheBoundedProbe() throws {
        let data = Data(#"{"isGitRepository":true,"currentBranch":"main"}"#.utf8)
        let status = try JSONDecoder().decode(WorkspaceSourceControlStatus.self, from: data)

        XCTAssertTrue(status.isGitRepository)
        XCTAssertEqual(status.currentBranch, "main")
    }

    func testSourceControlProjectionRetainsRepositoryWhileNextPathResolves() {
        let first = WorkspaceSourceControlStatus(isGitRepository: true, currentBranch: "main")
        let second = WorkspaceSourceControlStatus(isGitRepository: true, currentBranch: "feature")
        var projection = NewSessionSourceControlProjection()

        projection.beginProbe(for: "/tmp/first")
        projection.resolve(first, for: "/tmp/first")
        projection.beginProbe(for: "/tmp/second")

        XCTAssertEqual(projection.presentedGitStatus, first)
        XCTAssertNil(projection.status(for: "/tmp/second"))
        XCTAssertTrue(projection.isResolving("/tmp/second"))

        projection.resolve(second, for: "/tmp/second")

        XCTAssertEqual(projection.presentedGitStatus, second)
        XCTAssertEqual(projection.status(for: "/tmp/second"), second)
        XCTAssertFalse(projection.isResolving("/tmp/second"))
    }

    func testSourceControlProjectionRemovesRepositoryOnlyAfterNonRepositoryResolves() {
        let repository = WorkspaceSourceControlStatus(isGitRepository: true, currentBranch: "main")
        let folder = WorkspaceSourceControlStatus(isGitRepository: false, currentBranch: nil)
        var projection = NewSessionSourceControlProjection()

        projection.beginProbe(for: "/tmp/repository")
        projection.resolve(repository, for: "/tmp/repository")
        projection.beginProbe(for: "/tmp/folder")
        XCTAssertEqual(projection.presentedGitStatus, repository)

        projection.resolve(folder, for: "/tmp/folder")

        XCTAssertNil(projection.presentedGitStatus)
        XCTAssertEqual(projection.status(for: "/tmp/folder"), folder)
    }

    func testSourceControlProjectionRejectsLateResultsFromPriorWorkspace() {
        let repository = WorkspaceSourceControlStatus(isGitRepository: true, currentBranch: "main")
        var projection = NewSessionSourceControlProjection()

        projection.beginProbe(for: "/tmp/first")
        projection.beginProbe(for: "/tmp/second")
        projection.resolve(repository, for: "/tmp/first")

        XCTAssertNil(projection.presentedGitStatus)
        XCTAssertNil(projection.status(for: "/tmp/second"))
        XCTAssertTrue(projection.isResolving("/tmp/second"))
    }

    func testSourceControlProbeFailureMakesVersionSkewExplicitAndRetryable() {
        let versionSkew = NewSessionSourceControlProbeFailure(errorCode: "NOT_FOUND")
        XCTAssertEqual(versionSkew, .serverUpgradeRequired)
        XCTAssertEqual(versionSkew.value, "Server Update Required")
        XCTAssertTrue(versionSkew.caption.contains("Update or restart"))

        let retry = NewSessionSourceControlProbeFailure(errorCode: "INTERNAL_ERROR")
        XCTAssertEqual(retry, .retry)
        XCTAssertEqual(retry.value, "Could Not Check")
        XCTAssertTrue(retry.caption.contains("Tap to retry"))
    }

    func testWorkspaceSelectorUsesCurrentPathAsHeadTruncatedSheetTitle() throws {
        let source = try String(
            contentsOf: iosAppRoot()
                .appendingPathComponent("Sources/UI/Chat/Sheets/WorkspaceSelector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Text(sheetTitle)"))
        XCTAssertTrue(source.contains("currentPath.abbreviatingHomeDirectory"))
        XCTAssertTrue(source.contains(".truncationMode(.head)"))
        XCTAssertTrue(source.contains("Current folder, \\(sheetTitle)"))
        XCTAssertFalse(source.contains("locationSection"))
    }

    func testWorkspaceSelectorActionsShareTheShortcutPillPresentation() throws {
        let source = try String(
            contentsOf: iosAppRoot()
                .appendingPathComponent("Sources/UI/Chat/Sheets/WorkspaceSelectorRows.swift"),
            encoding: .utf8
        )
        let quickStart = try XCTUnwrap(source.range(of: "struct WorkspaceQuickPathPill"))
        let actionStart = try XCTUnwrap(source.range(of: "struct WorkspaceDirectoryActionPill"))
        let sharedStart = try XCTUnwrap(source.range(of: "private struct WorkspaceCompactPillButton"))
        let extensionStart = try XCTUnwrap(source.range(of: "private extension WorkspaceCompactPillButton"))
        let quick = source[quickStart.lowerBound..<actionStart.lowerBound]
        let action = source[actionStart.lowerBound..<sharedStart.lowerBound]
        let shared = source[sharedStart.lowerBound..<extensionStart.lowerBound]

        for owner in [quick, action] {
            XCTAssertTrue(owner.contains("WorkspaceCompactPillButton("))
            XCTAssertFalse(owner.contains(".contentShape(Capsule())"))
            XCTAssertFalse(owner.contains(".glassEffect("))
            XCTAssertFalse(owner.contains(".padding(.vertical"))
        }
        XCTAssertEqual(shared.components(separatedBy: ".contentShape(Capsule())").count - 1, 1)
        XCTAssertTrue(shared.contains(".padding(.horizontal, 10)"))
        XCTAssertTrue(shared.contains(".padding(.vertical, 7)"))
        XCTAssertTrue(shared.contains(".glassEffect("))
        XCTAssertFalse(source.contains(".frame(minHeight:"))
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
