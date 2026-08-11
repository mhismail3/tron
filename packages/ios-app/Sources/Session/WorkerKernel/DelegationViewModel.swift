import Foundation

struct DelegationArtifactReference: Identifiable, Equatable, Sendable {
    let type: String
    let pathOrURL: String
    let description: String

    var id: String { "\(type):\(pathOrURL)" }
}

struct DelegationEvidence: Identifiable, Equatable, Sendable {
    let kind: String
    let reference: String
    let description: String

    var id: String { "\(kind):\(reference):\(description)" }
}

struct DelegationConstraintObservation: Identifiable, Equatable, Sendable {
    let constraint: String
    let observed: Bool
    let evidence: String

    var id: String { constraint }
}

struct DelegationResult: Equatable, Sendable {
    let status: String
    let summary: String
    let deliverable: AnyCodable
    let artifacts: [DelegationArtifactReference]
    let evidence: [DelegationEvidence]
    let constraints: [DelegationConstraintObservation]
    let unresolvedItems: [String]
}

enum DelegationContractError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): "Delegation input is invalid: \(detail)"
        case .invalidResult(let detail): "General Delegate returned an invalid result: \(detail)"
        }
    }
}

enum DelegationContract {
    static let workerId = "general-delegate"
    static let experienceId = "general-delegate"
    static let suiteId = "delegation"
    static let contractVersion: UInt32 = 1

    static func primaryWorker(from workers: [WorkerSummaryDTO]) -> WorkerSummaryDTO? {
        workers.first { worker in
            guard worker.workerId == workerId,
                  let presentation = worker.presentation else { return false }
            return presentation.experienceId == experienceId
                && presentation.suiteId == suiteId
                && presentation.contractVersion == contractVersion
                && presentation.primary
        }
    }

    static func decodeResult(_ output: AnyCodable?) throws -> DelegationResult {
        let root = try dictionary(output?.value, field: "output")
        guard root["schema"] as? String == "delegation.result.v1" else {
            throw DelegationContractError.invalidResult("schema is not delegation.result.v1")
        }
        guard int(root["version"]) == 1 else {
            throw DelegationContractError.invalidResult("version is not 1")
        }
        let status = try string(root, "status")
        guard ["completed", "partial", "blocked", "failed"].contains(status) else {
            throw DelegationContractError.invalidResult("status is unsupported")
        }
        guard let deliverable = root["deliverable"] else {
            throw DelegationContractError.invalidResult("deliverable is missing")
        }
        return DelegationResult(
            status: status,
            summary: try string(root, "summary"),
            deliverable: AnyCodable(deliverable),
            artifacts: try array(root["artifactReferences"], field: "artifactReferences")
                .map(decodeArtifact),
            evidence: try array(root["evidence"], field: "evidence").map(decodeEvidence),
            constraints: try array(root["constraintsObserved"], field: "constraintsObserved")
                .map(decodeConstraint),
            unresolvedItems: try stringArray(root["unresolvedItems"], field: "unresolvedItems")
        )
    }

    static func task(from run: WorkerInvocationDTO) -> String {
        run.input?.dictionaryValue?["task"] as? String ?? "Delegated task"
    }

    static func deliverableDescription(from run: WorkerInvocationDTO) -> String? {
        guard let deliverable = AnyCodable(run.input?.dictionaryValue?["deliverable"]).dictionaryValue else {
            return nil
        }
        return deliverable["description"] as? String
    }

    static func runnerModel(from inspection: WorkerInspectResultDTO?) -> String? {
        guard let runner = inspection?.bundle["runner"]?.dictionaryValue else { return nil }
        return runner["model"] as? String
    }

    private static func decodeArtifact(_ value: Any) throws -> DelegationArtifactReference {
        let row = try dictionary(value, field: "artifactReference")
        return DelegationArtifactReference(
            type: try string(row, "type"),
            pathOrURL: try string(row, "pathOrUrl"),
            description: try string(row, "description")
        )
    }

    private static func decodeEvidence(_ value: Any) throws -> DelegationEvidence {
        let row = try dictionary(value, field: "evidence")
        return DelegationEvidence(
            kind: try string(row, "kind"),
            reference: try string(row, "reference"),
            description: try string(row, "description")
        )
    }

    private static func decodeConstraint(_ value: Any) throws -> DelegationConstraintObservation {
        let row = try dictionary(value, field: "constraint")
        guard let observed = row["observed"] as? Bool else {
            throw DelegationContractError.invalidResult("constraint.observed is missing")
        }
        return DelegationConstraintObservation(
            constraint: try string(row, "constraint"),
            observed: observed,
            evidence: try string(row, "evidence")
        )
    }

    private static func dictionary(_ value: Any?, field: String) throws -> [String: Any] {
        guard let value,
              let dictionary = AnyCodable(value).dictionaryValue else {
            throw DelegationContractError.invalidResult("\(field) is not an object")
        }
        return dictionary
    }

    private static func array(_ value: Any?, field: String) throws -> [Any] {
        guard let value,
              let array = AnyCodable(value).arrayValue else {
            throw DelegationContractError.invalidResult("\(field) is not an array")
        }
        return array
    }

    private static func stringArray(_ value: Any?, field: String) throws -> [String] {
        let values = try array(value, field: field)
        guard values.allSatisfy({ $0 is String }) else {
            throw DelegationContractError.invalidResult("\(field) contains a non-string value")
        }
        return values.compactMap { $0 as? String }
    }

    private static func string(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String else {
            throw DelegationContractError.invalidResult("\(key) is missing")
        }
        return value
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

@Observable
@MainActor
final class DelegationViewModel {
    var worker: WorkerSummaryDTO?
    var inspection: WorkerInspectResultDTO?
    var runs: [WorkerInvocationDTO] = []
    var attention: [WorkerInboxItemDTO] = []
    var resultsByInvocation: [String: DelegationResult] = [:]
    var task = ""
    var deliverableDescription = ""
    var context = ""
    var filePaths = ""
    var constraints = ""
    var deadline = ""
    var budget = "standard"
    var deliverableSchema = ""
    var isLoading = false
    var isMutating = false
    var hasLoaded = false
    var lastError: String?
    var lastSubmittedInvocationId: String?
    private var refreshGeneration = 0

    var activeRunCount: Int { runs.count { ["queued", "running"].contains($0.status) } }
    var completedRunCount: Int { runs.count { $0.status == "completed" } }
    var currentAttentionCount: Int {
        let unhealthyWorker = worker.map {
            WorkerConsolePresentation.status(for: $0).kind == .needsAttention ? 1 : 0
        } ?? 0
        let refreshProblem = lastError == nil ? 0 : 1
        return unhealthyWorker + attention.count + refreshProblem
    }
    var runnerModel: String? { DelegationContract.runnerModel(from: inspection) }
    var canSubmit: Bool {
        worker?.enabled == true
            && worker?.retired == false
            && !isMutating
            && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deliverableDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func resetForServerChange() {
        refreshGeneration &+= 1
        worker = nil
        inspection = nil
        runs = []
        attention = []
        resultsByInvocation = [:]
        isLoading = false
        isMutating = false
        hasLoaded = false
        lastError = nil
        lastSubmittedInvocationId = nil
    }

    func refresh(
        availableWorkers: [WorkerSummaryDTO],
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState
    ) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration

        guard connectionState.isConnected else {
            // Preserve the last authoritative suite projection while the
            // shared transport owns reconnection.
            return
        }
        guard let selected = DelegationContract.primaryWorker(from: availableWorkers) else {
            worker = nil
            inspection = nil
            runs = []
            attention = []
            resultsByInvocation = [:]
            hasLoaded = true
            lastError = "No supported General Delegate experience is active on this server."
            return
        }

        isLoading = true
        defer {
            if generation == refreshGeneration {
                isLoading = false
                hasLoaded = true
            }
        }

        if worker?.workerId != selected.workerId {
            inspection = nil
            runs = []
            attention = []
            resultsByInvocation = [:]
        }
        worker = selected

        var errors: [String] = []
        do {
            let loadedInspection = try await repository.inspectWorker(selected.workerId)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            inspection = loadedInspection
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
            errors.append("Contract: \(error.localizedDescription)")
        }

        do {
            let page = try await repository.workerRuns(workerId: selected.workerId, limit: 20)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            runs = page.runs.sorted { $0.createdAt > $1.createdAt }
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
            errors.append("Runs: \(error.localizedDescription)")
        }

        do {
            let page = try await repository.workerAttention(
                workerId: selected.workerId,
                limit: 20
            )
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            attention = page.items.sorted { $0.createdAt > $1.createdAt }
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
            errors.append("Attention: \(error.localizedDescription)")
        }

        var decoded: [String: DelegationResult] = [:]
        for run in runs {
            guard let output = run.output?.legacyInline,
                  output.dictionaryValue?["schema"] as? String == "delegation.result.v1" else {
                continue
            }
            do {
                decoded[run.invocationId] = try DelegationContract.decodeResult(output)
            } catch {
                // Historical output that no longer satisfies the native
                // presentation contract remains inspectable in the immutable
                // run detail. It is not current worker health.
                continue
            }
        }
        resultsByInvocation = decoded
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func submit(
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState,
        availableWorkers: [WorkerSummaryDTO]
    ) async -> Bool {
        guard connectionState.isConnected else {
            lastError = connectionState.displayText
            return false
        }
        guard let selected = worker ?? DelegationContract.primaryWorker(from: availableWorkers) else {
            lastError = "General Delegate is unavailable."
            return false
        }
        do {
            let input = try buildInput()
            isMutating = true
            defer { isMutating = false }
            let run = try await repository.enqueueWorker(
                workerId: selected.workerId,
                input: input,
                idempotencyKey: .userAction("delegation.enqueue")
            )
            lastSubmittedInvocationId = run.invocationId
            lastError = nil
            await refresh(
                availableWorkers: availableWorkers,
                repository: repository,
                connectionState: connectionState
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func retry(
        _ run: WorkerInvocationDTO,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState,
        availableWorkers: [WorkerSummaryDTO]
    ) async {
        guard connectionState.isConnected else {
            lastError = connectionState.displayText
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let retried = try await repository.enqueueWorker(
                workerId: run.workerId,
                input: run.input ?? AnyCodable([:]),
                idempotencyKey: .userAction("delegation.retry")
            )
            lastSubmittedInvocationId = retried.invocationId
            lastError = nil
            await refresh(
                availableWorkers: availableWorkers,
                repository: repository,
                connectionState: connectionState
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancel(
        _ run: WorkerInvocationDTO,
        repository: any WorkerKernelRepository,
        connectionState: ConnectionState,
        availableWorkers: [WorkerSummaryDTO]
    ) async {
        guard connectionState.isConnected,
              ["queued", "running"].contains(run.status) else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await repository.cancelWorkerInvocation(
                invocationId: run.invocationId,
                idempotencyKey: .userAction("delegation.cancel")
            )
            lastError = nil
            await refresh(
                availableWorkers: availableWorkers,
                repository: repository,
                connectionState: connectionState
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func buildInput() throws -> AnyCodable {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeliverable = deliverableDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else {
            throw DelegationContractError.invalidInput("task is required")
        }
        guard !trimmedDeliverable.isEmpty else {
            throw DelegationContractError.invalidInput("deliverable description is required")
        }
        var deliverable: [String: Any] = ["description": trimmedDeliverable]
        let trimmedSchema = deliverableSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSchema.isEmpty {
            let value = try JSONSerialization.jsonObject(with: Data(trimmedSchema.utf8))
            guard value is [String: Any] else {
                throw DelegationContractError.invalidInput("deliverable schema must be a JSON object")
            }
            deliverable["schema"] = value
        }

        var input: [String: Any] = [
            "task": trimmedTask,
            "deliverable": deliverable,
            "budget": budget,
        ]
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty { input["context"] = trimmedContext }
        let paths = lineValues(filePaths)
        if !paths.isEmpty { input["filePaths"] = paths }
        let constraints = lineValues(constraints)
        if !constraints.isEmpty { input["constraints"] = constraints }
        let trimmedDeadline = deadline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDeadline.isEmpty { input["deadline"] = trimmedDeadline }
        return AnyCodable(input)
    }

    private func lineValues(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
