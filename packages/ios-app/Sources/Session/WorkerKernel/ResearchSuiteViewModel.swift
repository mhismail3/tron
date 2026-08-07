import Foundation

struct ResearchSource: Identifiable, Equatable, Sendable {
    let sourceId: String
    let title: String
    let url: String
    let domain: String?
    let publisher: String?
    let publishedDate: String?
    let updatedDate: String?
    let accessedAt: String?

    var id: String { sourceId }
}

struct ResearchCitation: Identifiable, Equatable, Sendable {
    let citationId: String
    let claimId: String
    let sourceId: String
    let title: String
    let url: String
    let excerpts: [String]

    var id: String { citationId }
}

struct ResearchClaim: Identifiable, Equatable, Sendable {
    let claimId: String
    let text: String
    let classification: String
    let asserted: Bool
    let citationIds: [String]
    let rationale: String
    let uncertainty: [String]
    let gaps: [String]

    var id: String { claimId }
}

struct ResearchContradiction: Identifiable, Equatable, Sendable {
    let point: String
    let sourceIds: [String]
    let evidenceIds: [String]
    let uncertainty: String

    var id: String { "\(point):\(sourceIds.joined(separator: ","))" }
}

struct ResearchSpecialistOutcome: Identifiable, Equatable, Sendable {
    let role: String
    let called: Bool
    let status: String
    let errors: [String]
    let resultCount: Int?
    let sourceCount: Int?
    let evidenceCount: Int?
    let claimCount: Int?
    let supportedClaimCount: Int?
    let missingSecretBindings: [String]

    var id: String { role }

    var missingProviderNames: [String] {
        missingSecretBindings.map { binding in
            switch binding {
            case "provider-brave": "Brave Search"
            case "provider-exa": "Exa"
            default: WorkerConsolePresentation.displayLabel(binding)
            }
        }
    }
}

struct ResearchReport: Identifiable, Equatable, Sendable {
    let reportId: String
    let status: String
    let question: String
    let generatedAt: String
    let answerFormat: String
    let answer: String
    let claims: [ResearchClaim]
    let citations: [ResearchCitation]
    let sources: [ResearchSource]
    let contradictions: [ResearchContradiction]
    let evidenceGaps: [String]
    let limitations: [String]
    let outcomes: [ResearchSpecialistOutcome]

    var id: String { reportId }
    var supportedClaimCount: Int { claims.count { $0.classification == "supported" } }

    /// Historical execution evidence, not a projection of the profile's
    /// current credential state.
    var searchLimitation: String? {
        guard let search = outcomes.first(where: { $0.role == "search" }),
              search.status == "unavailable" else {
            return nil
        }
        let providers = search.missingProviderNames
        guard !providers.isEmpty else {
            return "Live search was unavailable for this run."
        }
        let providerList = providers.count == 2
            ? providers.joined(separator: " and ")
            : providers.joined(separator: ", ")
        let noun = providers.count == 1 ? "API key was" : "API keys were"
        return "Live search unavailable: \(providerList) \(noun) not configured for this run."
    }
}

enum ResearchSuiteContractError: Error, LocalizedError, Equatable {
    case invalidReport(String)

    var errorDescription: String? {
        switch self {
        case .invalidReport(let detail):
            "Research Coordinator returned an invalid report: \(detail)"
        }
    }
}

enum ResearchSuiteContract {
    static let experienceId = "research-suite"
    static let contractVersion: UInt32 = 1

    static func suiteWorkers(from workers: [WorkerSummaryDTO]) -> [WorkerSummaryDTO] {
        workers.filter { worker in
            guard let presentation = worker.presentation else { return false }
            return presentation.experienceId == experienceId
                && presentation.suiteId == experienceId
                && presentation.contractVersion == contractVersion
        }
        .sorted { componentOrder($0) < componentOrder($1) }
    }

    static func decodeReport(_ output: AnyCodable?) throws -> ResearchReport {
        let root = try dictionary(output?.value, field: "output")
        guard root["schema"] as? String == "research.report.v1" else {
            throw ResearchSuiteContractError.invalidReport("schema is not research.report.v1")
        }
        let answer = try dictionary(root["answer"], field: "answer")
        let outcomesRoot = try dictionary(root["specialistOutcomes"], field: "specialistOutcomes")
        return ResearchReport(
            reportId: try string(root, "reportId"),
            status: try string(root, "status"),
            question: try string(root, "question"),
            generatedAt: try string(root, "generatedAt"),
            answerFormat: try string(answer, "format"),
            answer: try string(answer, "content"),
            claims: try array(root["claims"], field: "claims").map(decodeClaim),
            citations: try array(root["citations"], field: "citations").map(decodeCitation),
            sources: try array(root["sourceManifest"], field: "sourceManifest").map(decodeSource),
            contradictions: try array(root["contradictions"], field: "contradictions").map(decodeContradiction),
            evidenceGaps: try stringArray(root["evidenceGaps"], field: "evidenceGaps"),
            limitations: try stringArray(root["limitations"], field: "limitations"),
            outcomes: ["search", "sourceReview", "citation", "storage"].compactMap { role in
                guard let value = outcomesRoot[role] else { return nil }
                return try? decodeOutcome(role: role, value: value)
            }
        )
    }

    static func query(from run: WorkerInvocationDTO) -> String? {
        guard let input = run.input.dictionaryValue else { return nil }
        for key in ["question", "query"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func componentOrder(_ worker: WorkerSummaryDTO) -> Int {
        switch worker.presentation?.componentRole {
        case "coordinator": 0
        case "search": 1
        case "source-review": 2
        case "citation": 3
        default: 4
        }
    }

    private static func decodeSource(_ value: Any) throws -> ResearchSource {
        let row = try dictionary(value, field: "source")
        return ResearchSource(
            sourceId: try string(row, "sourceId"),
            title: try string(row, "title"),
            url: try string(row, "url"),
            domain: optionalString(row["domain"]),
            publisher: optionalString(row["publisher"]),
            publishedDate: optionalString(row["publishedDate"]),
            updatedDate: optionalString(row["updatedDate"]),
            accessedAt: optionalString(row["accessedAt"])
        )
    }

    private static func decodeCitation(_ value: Any) throws -> ResearchCitation {
        let row = try dictionary(value, field: "citation")
        let excerpts = try array(row["excerpts"], field: "citation.excerpts").compactMap { value -> String? in
            let excerpt = try dictionary(value, field: "citation.excerpt")
            return excerpt["text"] as? String
        }
        return ResearchCitation(
            citationId: try string(row, "citationId"),
            claimId: try string(row, "claimId"),
            sourceId: try string(row, "sourceId"),
            title: try string(row, "title"),
            url: try string(row, "url"),
            excerpts: excerpts
        )
    }

    private static func decodeClaim(_ value: Any) throws -> ResearchClaim {
        let row = try dictionary(value, field: "claim")
        return ResearchClaim(
            claimId: try string(row, "claimId"),
            text: try string(row, "text"),
            classification: try string(row, "classification"),
            asserted: row["asserted"] as? Bool ?? false,
            citationIds: try stringArray(row["citationIds"], field: "claim.citationIds"),
            rationale: try string(row, "rationale"),
            uncertainty: try stringArray(row["uncertainty"], field: "claim.uncertainty"),
            gaps: try stringArray(row["gaps"], field: "claim.gaps")
        )
    }

    private static func decodeContradiction(_ value: Any) throws -> ResearchContradiction {
        let row = try dictionary(value, field: "contradiction")
        return ResearchContradiction(
            point: try string(row, "point"),
            sourceIds: try stringArray(row["sourceIds"], field: "contradiction.sourceIds"),
            evidenceIds: try stringArray(row["evidenceIds"], field: "contradiction.evidenceIds"),
            uncertainty: try string(row, "uncertainty")
        )
    }

    private static func decodeOutcome(role: String, value: Any) throws -> ResearchSpecialistOutcome {
        let row = try dictionary(value, field: "specialistOutcomes.\(role)")
        return ResearchSpecialistOutcome(
            role: role,
            called: row["called"] as? Bool ?? false,
            status: try string(row, "status"),
            errors: try optionalStringArray(row["errors"]),
            resultCount: optionalInt(row["resultCount"]),
            sourceCount: optionalInt(row["sourceCount"]),
            evidenceCount: optionalInt(row["evidenceCount"]),
            claimCount: optionalInt(row["claimCount"]),
            supportedClaimCount: optionalInt(row["supportedClaimCount"]),
            missingSecretBindings: try optionalStringArray(row["missingSecretBindings"])
        )
    }

    private static func dictionary(_ value: Any?, field: String) throws -> [String: Any] {
        guard let value,
              let dictionary = AnyCodable(value).dictionaryValue else {
            throw ResearchSuiteContractError.invalidReport("\(field) is not an object")
        }
        return dictionary
    }

    private static func array(_ value: Any?, field: String) throws -> [Any] {
        guard let value,
              let array = AnyCodable(value).arrayValue else {
            throw ResearchSuiteContractError.invalidReport("\(field) is not an array")
        }
        return array
    }

    private static func stringArray(_ value: Any?, field: String) throws -> [String] {
        let values = try array(value, field: field)
        guard values.allSatisfy({ $0 is String }) else {
            throw ResearchSuiteContractError.invalidReport("\(field) contains a non-string value")
        }
        return values.compactMap { $0 as? String }
    }

    private static func optionalStringArray(_ value: Any?) throws -> [String] {
        guard value != nil else { return [] }
        return try stringArray(value, field: "outcome array")
    }

    private static func string(_ row: [String: Any], _ key: String) throws -> String {
        guard let value = row[key] as? String else {
            throw ResearchSuiteContractError.invalidReport("\(key) is missing")
        }
        return value
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

@Observable
@MainActor
final class ResearchSuiteViewModel {
    var workers: [WorkerSummaryDTO] = []
    var runs: [WorkerInvocationDTO] = []
    var attention: [WorkerInboxItemDTO] = []
    var reports: [ResearchReport] = []
    var reportHistoryWarnings: [String] = []
    var isLoading = false
    var hasLoaded = false
    var lastError: String?
    private var refreshGeneration = 0

    var healthyComponentCount: Int {
        workers.count { $0.enabled && !$0.retired && $0.health == "healthy" }
    }

    var unhealthyComponentCount: Int {
        workers.count - healthyComponentCount
    }

    var currentAttentionCount: Int {
        unhealthyComponentCount + attention.count + (lastError == nil ? 0 : 1)
    }

    var latestReport: ResearchReport? { reports.first }

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

        isLoading = true
        defer {
            if generation == refreshGeneration {
                isLoading = false
                hasLoaded = true
            }
        }

        let selectedWorkers = ResearchSuiteContract.suiteWorkers(from: availableWorkers)
        var loadedRuns: [WorkerInvocationDTO] = []
        var loadedAttention: [WorkerInboxItemDTO] = []
        var errors: [String] = []

        for worker in selectedWorkers {
            do {
                loadedRuns += try await repository.workerRuns(
                    workerId: worker.workerId,
                    limit: 20
                ).runs
                guard !Task.isCancelled, generation == refreshGeneration else { return }
            } catch is CancellationError {
                return
            } catch {
                guard generation == refreshGeneration else { return }
                guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
                errors.append("\(worker.name) runs: \(error.localizedDescription)")
            }
            do {
                loadedAttention += try await repository.workerAttention(
                    workerId: worker.workerId,
                    limit: 20
                ).items
                guard !Task.isCancelled, generation == refreshGeneration else { return }
            } catch is CancellationError {
                return
            } catch {
                guard generation == refreshGeneration else { return }
                guard !ConnectionErrorClassifier.isTransientTransport(error) else { return }
                errors.append("\(worker.name) attention: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }
        workers = selectedWorkers
        runs = loadedRuns.sorted { $0.createdAt > $1.createdAt }
        attention = loadedAttention.sorted { $0.createdAt > $1.createdAt }
        let decoded = Self.decodeReports(from: runs)
        reports = decoded.reports
        reportHistoryWarnings = decoded.errors
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func resetForServerChange() {
        refreshGeneration &+= 1
        workers = []
        runs = []
        attention = []
        reports = []
        reportHistoryWarnings = []
        isLoading = false
        hasLoaded = false
        lastError = nil
    }

    func workerName(for workerId: String) -> String {
        workers.first { $0.workerId == workerId }?.name
            ?? WorkerConsolePresentation.displayLabel(workerId)
    }

    func callerWorkerName(for run: WorkerInvocationDTO) -> String? {
        guard let parentInvocationId = run.parentWorkerInvocationId,
              let parent = runs.first(where: { $0.invocationId == parentInvocationId }) else {
            return nil
        }
        return workerName(for: parent.workerId)
    }

    private static func decodeReports(
        from runs: [WorkerInvocationDTO]
    ) -> (reports: [ResearchReport], errors: [String]) {
        var seen: Set<String> = []
        var reports: [ResearchReport] = []
        var errors: [String] = []
        for run in runs where run.workerId == "research-coordinator" {
            guard let output = run.output?.legacyInline,
                  output.dictionaryValue?["schema"] as? String == "research.report.v1" else {
                continue
            }
            do {
                reports.append(try ResearchSuiteContract.decodeReport(output))
            } catch {
                errors.append("Coordinator run \(run.invocationId): \(error.localizedDescription)")
            }
        }
        reports = reports
            .filter { seen.insert($0.reportId).inserted }
            .sorted { $0.generatedAt > $1.generatedAt }
        return (reports, errors)
    }
}
