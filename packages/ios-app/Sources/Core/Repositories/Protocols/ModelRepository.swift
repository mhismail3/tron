import Foundation

// MARK: - Model Repository Protocol

/// Repository protocol for model operations.
/// Provides caching and abstraction over ModelClient.
@MainActor
protocol ModelRepository: AnyObject {
    /// Cached models from the last fetch
    var cachedModels: [ModelInfo] { get }

    /// Whether models are currently being loaded
    var isLoading: Bool { get }

    /// List available models with optional caching.
    /// - Parameter forceRefresh: Bypass cache and fetch fresh data
    /// - Returns: Array of available models
    func list(forceRefresh: Bool) async throws -> [ModelInfo]

    /// Switch the model for a session.
    /// - Parameters:
    ///   - sessionId: The session to switch models for
    ///   - modelId: The model ID to switch to
    /// - Returns: Result of the model switch
    func switchModel(sessionId: String, to modelId: String) async throws -> ModelSwitchResult

    /// Invalidate the model cache
    func invalidateCache()
}
