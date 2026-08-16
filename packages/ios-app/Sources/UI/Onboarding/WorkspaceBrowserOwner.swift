import Foundation
import Observation

typealias WorkspaceBrowserLoadOperation = @MainActor @Sendable () async throws -> Void
typealias WorkspaceBrowserRecovery = @MainActor @Sendable () -> Void
typealias WorkspaceBrowserMutationCompletion = @MainActor @Sendable () -> Void

@MainActor
@Observable
final class WorkspaceBrowserOwner {
    private(set) var loading = false
    private(set) var navigating = false
    private(set) var errorMessage: String?
    private(set) var submittingFolder = false

    private var generation: UInt64 = 0
    private var flight: Task<Void, Error>?

    func load(
        navigation: Bool,
        operation: @escaping WorkspaceBrowserLoadOperation,
        onTransientError: @escaping WorkspaceBrowserRecovery
    ) async {
        generation &+= 1
        let generation = generation
        flight?.cancel()
        loading = !navigation
        navigating = navigation
        submittingFolder = false

        let task = Task { try await operation() }
        flight = task
        do {
            try await task.value
            guard self.generation == generation else { return }
            errorMessage = nil
        } catch is CancellationError {
            guard self.generation == generation else { return }
        } catch {
            guard self.generation == generation else { return }
            let message = error.localizedDescription
            errorMessage = message
            if Self.isTransientConnectionError(message) { onTransientError() }
        }

        guard self.generation == generation else { return }
        flight = nil
        loading = false
        navigating = false
    }

    func createFolder(
        operation: @escaping WorkspaceBrowserLoadOperation,
        onSuccess: @escaping WorkspaceBrowserMutationCompletion,
        onTransientError: @escaping WorkspaceBrowserRecovery
    ) async {
        generation &+= 1
        let generation = generation
        flight?.cancel()
        flight = nil
        loading = false
        navigating = false
        submittingFolder = true
        do {
            // Folder creation may already have crossed the possibly-sent mutation
            // boundary, so presentation replacement gates its UI effects but does
            // not cancel the mutation task.
            try await operation()
            guard self.generation == generation else { return }
            errorMessage = nil
            onSuccess()
        } catch {
            guard self.generation == generation else { return }
            let message = error.localizedDescription
            errorMessage = message
            if Self.isTransientConnectionError(message) { onTransientError() }
        }
        guard self.generation == generation else { return }
        submittingFolder = false
    }

    func cancel() {
        generation &+= 1
        flight?.cancel()
        flight = nil
        loading = false
        navigating = false
        submittingFolder = false
    }

    static func isTransientConnectionError(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("gateway is offline")
            || value.localizedCaseInsensitiveContains("socket is not connected")
            || value.localizedCaseInsensitiveContains("disconnected")
    }
}
