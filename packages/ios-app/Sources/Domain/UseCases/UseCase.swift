import Foundation

// MARK: - Use Case Protocol

/// Base protocol for all Use Cases in the domain layer.
/// Use Cases encapsulate business logic and coordinate between repositories/services.
///
/// Usage:
/// ```swift
/// let useCase = SendMessageUseCase(agentClient: client)
/// let result = try await useCase.execute(.init(sessionId: "...", message: "Hello"))
/// ```
protocol UseCase<Request, Response> {
    associatedtype Request
    associatedtype Response

    /// Execute the use case with the given request.
    /// - Parameter request: The input data for the use case
    /// - Returns: The result of the use case execution
    /// - Throws: Any errors that occur during execution
    @MainActor
    func execute(_ request: Request) async throws -> Response
}

// MARK: - Void Request Use Case

/// Convenience protocol for use cases that don't require input parameters.
protocol VoidRequestUseCase<Response>: UseCase where Request == Void {
    @MainActor
    func execute() async throws -> Response
}

extension VoidRequestUseCase {
    @MainActor
    func execute(_ request: Void) async throws -> Response {
        try await execute()
    }
}
