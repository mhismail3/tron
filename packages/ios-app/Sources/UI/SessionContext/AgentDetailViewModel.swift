import Foundation

/// The presentation-safe outcome of one server-authored agent mutation.
/// Covered child sheets consume the message directly so a rejection is never
/// rendered only on the obscured parent detail sheet.
struct AgentMutationOutcome: Equatable, Sendable {
    let succeeded: Bool
    let errorMessage: String?

    static let success = AgentMutationOutcome(succeeded: true, errorMessage: nil)

    static func failure(_ message: String) -> AgentMutationOutcome {
        AgentMutationOutcome(succeeded: false, errorMessage: message)
    }
}

/// Retained, single-flight state for one agent detail hierarchy. Every stream
/// event is only an invalidation hint. Canonical head pages replace matching
/// records while retaining already-loaded history, and cursor generations
/// prevent a late poll from rewinding an in-flight pagination lane.
@Observable
@MainActor
final class AgentDetailViewModel {
    let ownerSessionId: String
    let agentId: String
    private let repository: any AgentRepository

    var inspect: AgentInspectDTO?
    var assignments: [AgentAssignmentDTO] = []
    var messages: [AgentMessageSummaryDTO] = []
    var assignmentsNextCursor: String?
    var messagesNextCursor: String?
    var isRefreshing = false
    var isLoadingOlderAssignments = false
    var isLoadingOlderMessages = false
    var assignmentsPageError: String?
    var messagesPageError: String?
    var isMutating = false
    var loadError: String?
    var mutationError: String?

    private var refreshRequested = false
    private var assignmentsPaginationGeneration: UInt64 = 0
    private var messagesPaginationGeneration: UInt64 = 0

    init(
        ownerSessionId: String,
        agentId: String,
        repository: any AgentRepository
    ) {
        self.ownerSessionId = ownerSessionId
        self.agentId = agentId
        self.repository = repository
    }

    func refresh() async {
        refreshRequested = true
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        while refreshRequested, !Task.isCancelled {
            refreshRequested = false
            await refreshOnce()
        }
    }

    private func refreshOnce() async {
        var errors: [String] = []
        do {
            inspect = try await repository.inspectAgent(
                ownerSessionId: ownerSessionId,
                agentId: agentId
            )
        } catch is CancellationError {
            return
        } catch {
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                errors.append("Overview: \(error.localizedDescription)")
            }
        }

        let assignmentsGeneration = assignmentsPaginationGeneration
        do {
            let page = try await repository.agentAssignments(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                cursor: nil,
                limit: 40
            )
            guard !Task.isCancelled else { return }
            assignments = mergingRefreshedHead(
                page.items,
                into: assignments,
                id: \.assignmentId
            )
            if assignmentsGeneration == 0,
               assignmentsPaginationGeneration == assignmentsGeneration,
               !isLoadingOlderAssignments {
                assignmentsNextCursor = page.nextCursor
            }
        } catch is CancellationError {
            return
        } catch {
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                errors.append("Assignments: \(error.localizedDescription)")
            }
        }

        let messagesGeneration = messagesPaginationGeneration
        do {
            let page = try await repository.agentMessages(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                cursor: nil,
                limit: 50
            )
            guard !Task.isCancelled else { return }
            messages = mergingRefreshedHead(
                page.items,
                into: messages,
                id: \.messageId
            )
            if messagesGeneration == 0,
               messagesPaginationGeneration == messagesGeneration,
               !isLoadingOlderMessages {
                messagesNextCursor = page.nextCursor
            }
        } catch is CancellationError {
            return
        } catch {
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                errors.append("Messages: \(error.localizedDescription)")
            }
        }
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func loadOlderAssignments() async {
        guard !isLoadingOlderAssignments, let cursor = assignmentsNextCursor else { return }
        let generation = assignmentsPaginationGeneration
        isLoadingOlderAssignments = true
        assignmentsPageError = nil
        defer { isLoadingOlderAssignments = false }
        do {
            let page = try await repository.agentAssignments(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                cursor: cursor,
                limit: 40
            )
            guard !Task.isCancelled,
                  assignmentsPaginationGeneration == generation,
                  assignmentsNextCursor == cursor else { return }
            appendUnique(page.items, to: &assignments, id: \.assignmentId)
            assignmentsNextCursor = page.nextCursor
            assignmentsPaginationGeneration &+= 1
        } catch is CancellationError {
            return
        } catch {
            assignmentsPageError = "Could not load older assignments: \(error.localizedDescription)"
        }
    }

    func loadOlderMessages() async {
        guard !isLoadingOlderMessages, let cursor = messagesNextCursor else { return }
        let generation = messagesPaginationGeneration
        isLoadingOlderMessages = true
        messagesPageError = nil
        defer { isLoadingOlderMessages = false }
        do {
            let page = try await repository.agentMessages(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                cursor: cursor,
                limit: 50
            )
            guard !Task.isCancelled,
                  messagesPaginationGeneration == generation,
                  messagesNextCursor == cursor else { return }
            appendUnique(page.items, to: &messages, id: \.messageId)
            messagesNextCursor = page.nextCursor
            messagesPaginationGeneration &+= 1
        } catch is CancellationError {
            return
        } catch {
            messagesPageError = "Could not load older messages: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func sendOperatorMessage(_ content: String) async -> AgentMutationOutcome {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Enter an instruction before sending.")
        }
        return await performMutation {
            try await self.repository.sendOperatorMessage(
                ownerSessionId: self.ownerSessionId,
                agentId: self.agentId,
                content: trimmed,
                idempotencyKey: .userAction("agent.operator-message")
            )
        }
    }

    @discardableResult
    func manage(
        action: String,
        assignmentId: String? = nil,
        cascade: Bool? = nil,
        configuration: AnyCodable? = nil
    ) async -> AgentMutationOutcome {
        await performMutation {
            try await self.repository.manageAgent(
                ownerSessionId: self.ownerSessionId,
                agentId: self.agentId,
                action: action,
                assignmentId: assignmentId,
                cascade: cascade,
                configuration: configuration,
                idempotencyKey: .userAction("agent.manage.\(action)")
            )
        }
    }

    @discardableResult
    func retry(_ assignmentId: String) async -> AgentMutationOutcome {
        await performMutation {
            try await self.repository.retryAgentAssignment(
                ownerSessionId: self.ownerSessionId,
                agentId: self.agentId,
                assignmentId: assignmentId,
                idempotencyKey: .userAction("agent.assignment.retry")
            )
        }
    }

    @discardableResult
    func promote() async -> AgentMutationOutcome {
        await performMutation {
            try await self.repository.promoteAgent(
                ownerSessionId: self.ownerSessionId,
                agentId: self.agentId,
                idempotencyKey: .userAction("agent.promote")
            )
        }
    }

    private func performMutation(
        _ operation: @escaping @MainActor () async throws -> AgentMutationResultDTO
    ) async -> AgentMutationOutcome {
        guard !isMutating else {
            return .failure("Another agent change is still in progress.")
        }
        isMutating = true
        mutationError = nil
        defer { isMutating = false }
        do {
            let result = try await operation()
            inspect = result.agent
            await refresh()
            return .success
        } catch is CancellationError {
            let message = "The operation was cancelled before it completed."
            mutationError = message
            return .failure(message)
        } catch {
            let message = error.localizedDescription
            mutationError = message
            return .failure(message)
        }
    }

    /// Replaces current head records with canonical values while preserving
    /// every distinct historical row already loaded by explicit pagination.
    private func mergingRefreshedHead<Element>(
        _ incoming: [Element],
        into existing: [Element],
        id: KeyPath<Element, String>
    ) -> [Element] {
        var identifiers: Set<String> = []
        var merged = incoming.filter { identifiers.insert($0[keyPath: id]).inserted }
        merged.append(contentsOf: existing.filter {
            identifiers.insert($0[keyPath: id]).inserted
        })
        return merged
    }

    private func appendUnique<Element>(
        _ incoming: [Element],
        to existing: inout [Element],
        id: KeyPath<Element, String>
    ) {
        var identifiers = Set(existing.map { $0[keyPath: id] })
        existing.append(contentsOf: incoming.filter {
            identifiers.insert($0[keyPath: id]).inserted
        })
    }

}
