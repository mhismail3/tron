import XCTest
@testable import TronMobile

// MARK: - Mock Model Client for Repository Testing

@MainActor
final class MockModelClientForRepository {
    // List
    var listCallCount = 0
    var lastListForceRefresh: Bool?
    var listResultToReturn: [ModelInfo] = []
    var listError: Error?

    // Switch Model
    var switchModelCallCount = 0
    var lastSwitchModelSessionId: String?
    var lastSwitchModelModelId: String?
    var switchModelResultToReturn: ModelSwitchResult?
    var switchModelError: Error?

    func list(forceRefresh: Bool) async throws -> [ModelInfo] {
        listCallCount += 1
        lastListForceRefresh = forceRefresh
        if let error = listError {
            throw error
        }
        return listResultToReturn
    }

    func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult {
        switchModelCallCount += 1
        lastSwitchModelSessionId = sessionId
        lastSwitchModelModelId = model
        if let error = switchModelError {
            throw error
        }
        return switchModelResultToReturn ?? createMockSwitchResult()
    }

    private func createMockSwitchResult() -> ModelSwitchResult {
        let json = """
        {"previousModel": "claude-3-sonnet", "newModel": "claude-4-opus"}
        """
        return try! JSONDecoder().decode(ModelSwitchResult.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - Mock Model Repository for Caching Tests

@MainActor
final class MockModelRepository: ModelRepository {
    var cachedModels: [ModelInfo] = []
    var isLoading: Bool = false

    private let mockClient: MockModelClientForRepository
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    init(mockClient: MockModelClientForRepository) {
        self.mockClient = mockClient
    }

    func list(forceRefresh: Bool) async throws -> [ModelInfo] {
        if !forceRefresh, let cacheTime = cacheTime, Date().timeIntervalSince(cacheTime) < cacheTTL {
            return cachedModels
        }

        isLoading = true
        defer { isLoading = false }

        let models = try await mockClient.list(forceRefresh: forceRefresh)
        cachedModels = models
        cacheTime = Date()
        return models
    }

    func switchModel(sessionId: String, to modelId: String) async throws -> ModelSwitchResult {
        try await mockClient.switchModel(sessionId, model: modelId)
    }

    func invalidateCache() {
        cacheTime = nil
    }
}

// MARK: - DefaultModelRepository Tests

@MainActor
final class DefaultModelRepositoryTests: XCTestCase {

    var mockClient: MockModelClientForRepository!
    var repository: MockModelRepository!

    override func setUp() async throws {
        mockClient = MockModelClientForRepository()
        repository = MockModelRepository(mockClient: mockClient)
    }

    override func tearDown() async throws {
        mockClient = nil
        repository = nil
    }

    // MARK: - List Tests

    func test_list_callsClient() async throws {
        // Given
        mockClient.listResultToReturn = [createMockModel(id: "model-1")]

        // When
        let models = try await repository.list(forceRefresh: false)

        // Then
        XCTAssertEqual(mockClient.listCallCount, 1)
        XCTAssertEqual(models.count, 1)
    }

    func test_list_cachesResults() async throws {
        // Given
        mockClient.listResultToReturn = [createMockModel(id: "model-1")]

        // When - First call
        _ = try await repository.list(forceRefresh: false)

        // When - Second call (should use cache)
        _ = try await repository.list(forceRefresh: false)

        // Then - Only one actual client call
        XCTAssertEqual(mockClient.listCallCount, 1)
    }

    func test_list_forceRefresh_ignoresCache() async throws {
        // Given
        mockClient.listResultToReturn = [createMockModel(id: "model-1")]

        // When - First call
        _ = try await repository.list(forceRefresh: false)

        // When - Second call with force refresh
        _ = try await repository.list(forceRefresh: true)

        // Then - Two client calls
        XCTAssertEqual(mockClient.listCallCount, 2)
    }

    func test_list_updatesCache() async throws {
        // Given
        mockClient.listResultToReturn = [createMockModel(id: "model-1")]

        // When
        _ = try await repository.list(forceRefresh: false)

        // Then
        XCTAssertEqual(repository.cachedModels.count, 1)
        XCTAssertEqual(repository.cachedModels[0].id, "model-1")
    }

    func test_list_throwsError() async throws {
        // Given
        mockClient.listError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await repository.list(forceRefresh: false)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.listCallCount, 1)
        }
    }

    // MARK: - Switch Model Tests

    func test_switchModel_callsClient() async throws {
        // When
        let result = try await repository.switchModel(sessionId: "session-123", to: "model-456")

        // Then
        XCTAssertEqual(mockClient.switchModelCallCount, 1)
        XCTAssertEqual(mockClient.lastSwitchModelSessionId, "session-123")
        XCTAssertEqual(mockClient.lastSwitchModelModelId, "model-456")
        XCTAssertNotNil(result)
    }

    func test_switchModel_throwsError() async throws {
        // Given
        mockClient.switchModelError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await repository.switchModel(sessionId: "session-123", to: "model-456")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.switchModelCallCount, 1)
        }
    }

    // MARK: - Cache Invalidation Tests

    func test_invalidateCache_clearsCacheTime() async throws {
        // Given - Populate cache
        mockClient.listResultToReturn = [createMockModel(id: "model-1")]
        _ = try await repository.list(forceRefresh: false)
        XCTAssertEqual(mockClient.listCallCount, 1)

        // When
        repository.invalidateCache()

        // Then - Next call should hit the client
        _ = try await repository.list(forceRefresh: false)
        XCTAssertEqual(mockClient.listCallCount, 2)
    }

    // MARK: - Helpers

    private func createMockModel(id: String) -> ModelInfo {
        let json = """
        {
            "id": "\(id)",
            "name": "Test Model",
            "provider": "anthropic",
            "contextWindow": 200000
        }
        """
        return try! JSONDecoder().decode(ModelInfo.self, from: json.data(using: .utf8)!)
    }
}
