import Foundation
import XCTest
@testable import TronMobile

// MARK: - DefaultModelRepository Tests

@MainActor
final class DefaultModelRepositoryTests: XCTestCase {

    var transport: MockEngineTransport!
    var repository: DefaultModelRepository!

    override func setUp() async throws {
        transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:9847/engine")!
        )
        repository = DefaultModelRepository(modelClient: ModelClient(transport: transport))
    }

    override func tearDown() async throws {
        repository = nil
        transport = nil
    }

    // MARK: - List Tests

    func test_list_callsClient() async throws {
        // Given
        stubModelList([createMockModel(id: "model-1")])

        // When
        let models = try await repository.list(forceRefresh: false)

        // Then
        XCTAssertEqual(modelListCallCount, 1)
        XCTAssertEqual(models.count, 1)
    }

    func test_list_cachesResults() async throws {
        // Given
        stubModelList([createMockModel(id: "model-1")])

        // When - First call
        _ = try await repository.list(forceRefresh: false)

        // When - Second call (should use cache)
        _ = try await repository.list(forceRefresh: false)

        // Then - Only one actual client call
        XCTAssertEqual(modelListCallCount, 1)
    }

    func test_list_forceRefresh_ignoresCache() async throws {
        // Given
        stubModelList([createMockModel(id: "model-1")])

        // When - First call
        _ = try await repository.list(forceRefresh: false)

        // When - Second call with force refresh
        _ = try await repository.list(forceRefresh: true)

        // Then - Two client calls
        XCTAssertEqual(modelListCallCount, 2)
    }

    func test_list_updatesCache() async throws {
        // Given
        stubModelList([createMockModel(id: "model-1")])

        // When
        _ = try await repository.list(forceRefresh: false)

        // Then
        XCTAssertEqual(repository.cachedModels.count, 1)
        XCTAssertEqual(repository.cachedModels[0].id, "model-1")
    }

    func test_list_updatesFormatterFromFetchedCatalog() async throws {
        let modelId = "repository-owned-formatter-model"
        stubModelList([createMockModel(id: modelId)])

        _ = try await repository.list(forceRefresh: false)

        XCTAssertEqual(ModelNameFormatter.format(modelId, style: .short), "Test Model")
    }

    func test_list_throwsError() async throws {
        // Given
        transport.readHandler = { _, _, _ in
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }

        // When/Then
        do {
            _ = try await repository.list(forceRefresh: false)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(modelListCallCount, 1)
        }
    }

    // MARK: - Switch Model Tests

    func test_switchModel_callsClient() async throws {
        let idempotencyKey = EngineIdempotencyKey.userAction("model.switch.repository.test")
        transport.currentSessionId = "session-123"
        transport.writeHandler = { functionId, payload, receivedKey, options in
            XCTAssertEqual(functionId.rawValue, "model::switch")
            XCTAssertEqual((payload as? ModelSwitchParams)?.sessionId, "session-123")
            XCTAssertEqual((payload as? ModelSwitchParams)?.model, "model-456")
            XCTAssertEqual(receivedKey, idempotencyKey)
            XCTAssertEqual(options.context?.sessionId, "session-123")
            return ModelSwitchResult(previousModel: "model-123", newModel: "model-456")
        }

        // When
        let result = try await repository.switchModel(
            sessionId: "session-123",
            to: "model-456",
            idempotencyKey: idempotencyKey
        )

        // Then
        XCTAssertEqual(transport.operationOrder, ["write:model::switch"])
        XCTAssertEqual(transport.lastSetModel, "model-456")
        XCTAssertEqual(result.newModel, "model-456")
    }

    func test_switchModel_throwsError() async throws {
        // Given
        transport.writeHandler = { _, _, _, _ in
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }

        // When/Then
        do {
            _ = try await repository.switchModel(
                sessionId: "session-123",
                to: "model-456",
                idempotencyKey: .userAction("model.switch.repository.test")
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(transport.operationOrder, ["write:model::switch"])
        }
    }

    func test_setReasoningLevel_callsClient() async throws {
        let idempotencyKey = EngineIdempotencyKey.userAction("reasoning.repository.test")
        transport.writeHandler = { functionId, payload, receivedKey, options in
            XCTAssertEqual(functionId.rawValue, "config::set_reasoning_level")
            XCTAssertEqual((payload as? ReasoningLevelParams)?.sessionId, "session-123")
            XCTAssertEqual((payload as? ReasoningLevelParams)?.level, "high")
            XCTAssertEqual(receivedKey, idempotencyKey)
            XCTAssertEqual(options.context?.sessionId, "session-123")
            return ReasoningLevelResult(previousLevel: "medium", newLevel: "high", changed: true)
        }

        let result = try await repository.setReasoningLevel(
            sessionId: "session-123",
            level: "high",
            idempotencyKey: idempotencyKey
        )

        XCTAssertEqual(transport.operationOrder, ["write:config::set_reasoning_level"])
        XCTAssertEqual(result.newLevel, "high")
        XCTAssertTrue(result.changed)
    }

    // MARK: - Cache Invalidation Tests

    func test_invalidateCache_clearsCatalogAndForcesReload() async throws {
        // Given - Populate cache
        stubModelList([createMockModel(id: "model-1")])
        _ = try await repository.list(forceRefresh: false)
        XCTAssertEqual(modelListCallCount, 1)

        // When
        repository.invalidateCache()
        XCTAssertTrue(repository.cachedModels.isEmpty)

        // Then - Next call should hit the client
        _ = try await repository.list(forceRefresh: false)
        XCTAssertEqual(modelListCallCount, 2)
    }

    // MARK: - Helpers

    private var modelListCallCount: Int {
        transport.operationOrder.count { $0 == "read:model::list" }
    }

    private func stubModelList(_ models: [ModelInfo]) {
        transport.readHandler = { functionId, payload, _ in
            XCTAssertEqual(functionId.rawValue, "model::list")
            XCTAssertTrue(payload is EmptyParams)
            return ModelListResult(models: models)
        }
    }

    private func createMockModel(id: String) -> ModelInfo {
        // I8: supportsThinking/Images/Documents, tier, and isRetiredGeneration are
        // required on the wire — the server emits them unconditionally.
        let json = """
        {
            "id": "\(id)",
            "name": "Test Model",
            "provider": "anthropic",
            "contextWindow": 200000,
            "supportsThinking": true,
            "supportsImages": true,
            "supportsDocuments": true,
            "attachmentPolicy": {
                "supportsPdfContent": true,
                "supportsTextFiles": true,
                "maxImageDimension": 1568,
                "maxImageBytes": 1400000,
                "maxDocumentBytes": 20971520,
                "supportedImageMimeTypes": ["image/jpeg", "image/png"]
            },
            "tier": "sonnet",
            "isLegacy": false
        }
        """
        return try! JSONDecoder().decode(ModelInfo.self, from: json.data(using: .utf8)!)
    }
}
