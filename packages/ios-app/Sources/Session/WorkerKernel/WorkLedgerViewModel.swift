import Foundation

enum WorkerExperienceRoute: Equatable {
    case workLedger
    case genericConsole

    static func resolve(_ worker: WorkerSummaryDTO) -> Self {
        guard let presentation = worker.presentation,
              presentation.experienceId == "work-ledger",
              presentation.contractVersion == 1,
              presentation.primary else {
            return .genericConsole
        }
        return .workLedger
    }
}

struct WorkLedgerGoal: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
    let cancelledAt: String?
    let cancelReason: String?
}

struct WorkLedgerQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let goalId: String?
    let text: String
    let status: String
    let answer: String?
    let createdAt: String
    let updatedAt: String
    let answeredAt: String?
    let resolvedAt: String?
}

struct WorkLedgerDecision: Identifiable, Equatable, Sendable {
    let id: String
    let goalId: String?
    let questionId: String?
    let title: String
    let rationale: String
    let createdAt: String
}

struct WorkLedgerHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: String
    let entityType: String
    let entityId: String
    let action: String
}

struct WorkLedgerSnapshot: Equatable, Sendable {
    let goals: [WorkLedgerGoal]
    let questions: [WorkLedgerQuestion]
    let decisions: [WorkLedgerDecision]
    let recentHistory: [WorkLedgerHistoryEntry]

    static let empty = WorkLedgerSnapshot(
        goals: [],
        questions: [],
        decisions: [],
        recentHistory: []
    )

    var activeGoalCount: Int { goals.count { $0.status == "active" } }
    var openQuestionCount: Int { questions.count { $0.status == "open" } }
    var decisionCount: Int { decisions.count }
}

enum WorkLedgerContractError: Error, LocalizedError, Equatable {
    case invalidResponse(String)
    case workerFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            "Work Ledger returned an invalid response: \(detail)"
        case .workerFailure(let detail):
            detail
        }
    }
}

enum WorkLedgerContract {
    static func decodeSnapshot(_ output: AnyCodable?) throws -> WorkLedgerSnapshot {
        let root = try dictionary(output?.value, field: "output")
        guard root["ok"] as? Bool == true else {
            throw WorkLedgerContractError.workerFailure(
                root["error"] as? String ?? "Work Ledger could not load its current state."
            )
        }
        let snapshot = try dictionary(root["snapshot"], field: "snapshot")
        return WorkLedgerSnapshot(
            goals: try array(snapshot["goals"], field: "snapshot.goals").map(decodeGoal),
            questions: try array(snapshot["questions"], field: "snapshot.questions").map(decodeQuestion),
            decisions: try array(snapshot["decisions"], field: "snapshot.decisions").map(decodeDecision),
            recentHistory: try array(
                snapshot["recent_history"],
                field: "snapshot.recent_history"
            ).map(decodeHistory)
        )
    }

    static func validateMutation(_ output: AnyCodable?) throws {
        let root = try dictionary(output?.value, field: "output")
        guard root["ok"] as? Bool == true else {
            throw WorkLedgerContractError.workerFailure(
                root["error"] as? String ?? "Work Ledger rejected the requested change."
            )
        }
    }

    private static func decodeGoal(_ value: Any) throws -> WorkLedgerGoal {
        let row = try dictionary(value, field: "goal")
        return WorkLedgerGoal(
            id: try string(row, "id"),
            title: try string(row, "title"),
            description: row["description"] as? String ?? "",
            status: try string(row, "status"),
            createdAt: try string(row, "created_at"),
            updatedAt: try string(row, "updated_at"),
            completedAt: optionalString(row["completed_at"]),
            cancelledAt: optionalString(row["cancelled_at"]),
            cancelReason: optionalString(row["cancel_reason"])
        )
    }

    private static func decodeQuestion(_ value: Any) throws -> WorkLedgerQuestion {
        let row = try dictionary(value, field: "question")
        return WorkLedgerQuestion(
            id: try string(row, "id"),
            goalId: optionalString(row["goal_id"]),
            text: try string(row, "text"),
            status: try string(row, "status"),
            answer: optionalString(row["answer"]),
            createdAt: try string(row, "created_at"),
            updatedAt: try string(row, "updated_at"),
            answeredAt: optionalString(row["answered_at"]),
            resolvedAt: optionalString(row["resolved_at"])
        )
    }

    private static func decodeDecision(_ value: Any) throws -> WorkLedgerDecision {
        let row = try dictionary(value, field: "decision")
        return WorkLedgerDecision(
            id: try string(row, "id"),
            goalId: optionalString(row["goal_id"]),
            questionId: optionalString(row["question_id"]),
            title: try string(row, "title"),
            rationale: row["rationale"] as? String ?? "",
            createdAt: try string(row, "created_at")
        )
    }

    private static func decodeHistory(_ value: Any) throws -> WorkLedgerHistoryEntry {
        let row = try dictionary(value, field: "history")
        guard let id = row["id"] as? Int else {
            throw WorkLedgerContractError.invalidResponse("history.id is missing")
        }
        return WorkLedgerHistoryEntry(
            id: id,
            timestamp: try string(row, "ts"),
            entityType: try string(row, "entity_type"),
            entityId: try string(row, "entity_id"),
            action: try string(row, "action")
        )
    }

    private static func dictionary(_ value: Any?, field: String) throws -> [String: Any] {
        guard let value,
              let dictionary = AnyCodable(value).dictionaryValue else {
            throw WorkLedgerContractError.invalidResponse("\(field) is not an object")
        }
        return dictionary
    }

    private static func array(_ value: Any?, field: String) throws -> [Any] {
        guard let value,
              let array = AnyCodable(value).arrayValue else {
            throw WorkLedgerContractError.invalidResponse("\(field) is not an array")
        }
        return array
    }

    private static func string(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String else {
            throw WorkLedgerContractError.invalidResponse("\(key) is missing")
        }
        return value
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }
}

@Observable
@MainActor
final class WorkLedgerViewModel {
    var snapshot = WorkLedgerSnapshot.empty
    var isLoading = false
    var isMutating = false
    var hasLoaded = false
    var lastError: String?
    var lastInvocationId: String?

    func refresh(
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        guard connectionState.isConnected else {
            snapshot = .empty
            hasLoaded = true
            lastError = connectionState.displayText
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let result = try await repository.invokeWorker(
                workerId: workerId,
                input: AnyCodable(["action": "snapshot", "history_limit": 50]),
                idempotencyKey: .userAction("work-ledger.snapshot")
            )
            lastInvocationId = result.invocationId
            snapshot = try WorkLedgerContract.decodeSnapshot(result.output)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createGoal(
        title: String,
        description: String,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        await mutate(
            action: "create_goal",
            fields: ["title": title, "description": description],
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func updateGoal(
        goalId: String,
        title: String,
        description: String,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        await mutate(
            action: "update_goal",
            fields: ["goal_id": goalId, "title": title, "description": description],
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func completeGoal(
        _ goalId: String,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        await mutate(
            action: "complete_goal",
            fields: ["goal_id": goalId],
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func cancelGoal(
        _ goalId: String,
        reason: String,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        await mutate(
            action: "cancel_goal",
            fields: ["goal_id": goalId, "reason": reason],
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func createQuestion(
        text: String,
        goalId: String?,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        var fields: [String: Any] = ["text": text]
        if let goalId, !goalId.isEmpty { fields["goal_id"] = goalId }
        return await mutate(
            action: "create_question",
            fields: fields,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func answerQuestion(
        _ questionId: String,
        answer: String,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        await mutate(
            action: "answer_question",
            fields: ["question_id": questionId, "answer": answer],
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func resolveQuestion(
        _ questionId: String,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        await mutate(
            action: "resolve_question",
            fields: ["question_id": questionId],
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    func recordDecision(
        title: String,
        rationale: String,
        goalId: String?,
        questionId: String?,
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        var fields: [String: Any] = ["title": title, "rationale": rationale]
        if let goalId, !goalId.isEmpty { fields["goal_id"] = goalId }
        if let questionId, !questionId.isEmpty { fields["question_id"] = questionId }
        return await mutate(
            action: "record_decision",
            fields: fields,
            workerId: workerId,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func mutate(
        action: String,
        fields: [String: Any],
        workerId: String,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async -> Bool {
        guard connectionState.isConnected, !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            var input = fields
            input["action"] = action
            let result = try await repository.invokeWorker(
                workerId: workerId,
                input: AnyCodable(input),
                idempotencyKey: .userAction("work-ledger.\(action)")
            )
            lastInvocationId = result.invocationId
            try WorkLedgerContract.validateMutation(result.output)
            lastError = nil
            await refresh(
                workerId: workerId,
                repository: repository,
                connectionState: connectionState
            )
            return lastError == nil
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
