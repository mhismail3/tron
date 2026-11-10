import Foundation
import Observation
import TronMobileCore

struct ProviderAuthPromptState: Identifiable, Hashable {
    enum Kind: String { case text, secret, select, manualCode = "manual_code" }

    struct Option: Hashable, Identifiable {
        let id: String
        let label: String
        let description: String?
    }

    let id: String
    let operationId: String
    let kind: Kind
    let message: String
    let placeholder: String?
    let options: [Option]
}

enum ProviderAuthBrowserPolicy {
    static func supportsManualCallback(event: ProviderAuthEventState, prompt: ProviderAuthPromptState?) -> Bool {
        guard let prompt, prompt.operationId == event.operationId else { return false }
        return prompt.kind == .text || prompt.kind == .manualCode
    }
}

struct ProviderAuthEventState: Identifiable, Hashable {
    struct Link: Hashable, Identifiable {
        let url: URL
        let label: String?
        var id: String { url.absoluteString }
    }

    enum Kind: String { case info, authURL = "auth_url", deviceCode = "device_code", progress }

    let operationId: String
    let kind: Kind
    let message: String?
    let links: [Link]
    let url: URL?
    let instructions: String?
    let userCode: String?
    let verificationURL: URL?
    let intervalSeconds: Int?
    let expiresInSeconds: Int?
    let callbackCapture: ProviderOAuthCallbackCapture?
    var id: String { operationId }
}

@MainActor
protocol ProviderAuthCoordinatorDelegate: AnyObject {
    func providerAuthCoordinatorSurface(_ error: Error)
    func providerAuthCoordinatorSetCompletionError(_ message: String?)
}

enum ProviderCatalogPolicy {
    static let maximumItems = 1_000
    static let maximumStringBytes = 4 * 1_048_576

    static func validate(_ providers: [ProviderSummary]) throws {
        guard providers.count <= maximumItems else { throw invalidCatalog() }
        var identities = Set<String>()
        var stringBytes = 0
        for provider in providers {
            guard identities.insert(provider.id).inserted else { throw invalidCatalog() }
            let values = [provider.id, provider.name]
                + [provider.authSource, provider.credentialType].compactMap { $0 }
                + provider.authMethods
            for value in values {
                let count = value.utf8.count
                guard stringBytes <= maximumStringBytes,
                      count <= maximumStringBytes - stringBytes else {
                    throw invalidCatalog()
                }
                stringBytes += count
            }
        }
    }

    private static func invalidCatalog() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_catalog",
            message: "Tron returned an invalid or oversized provider catalog.",
            retryable: true,
            details: nil
        )
    }
}

enum ModelCatalogPolicy {
    static let requestPageSize = 500
    static let maximumPages = 50
    static let maximumItems = 25_000
    static let maximumStringBytes = 16 * 1_048_576

    static func admitsStringBytes(current: Int, candidate: Int) -> Bool {
        guard current >= 0, current <= maximumStringBytes, candidate >= 0 else { return false }
        return candidate <= maximumStringBytes - current
    }
}

enum RecentModelCatalogPolicy {
    static let maximumItems = 12
    static let maximumStringBytes = 512

    static func admit(_ models: [RecentModelRef]) -> [RecentModelRef] {
        var seen = Set<ModelRef>()
        var admitted: [RecentModelRef] = []
        admitted.reserveCapacity(min(models.count, maximumItems))
        for model in models {
            guard admitted.count < maximumItems,
                  !model.provider.isEmpty,
                  !model.id.isEmpty,
                  model.provider.utf8.count <= maximumStringBytes,
                  model.id.utf8.count <= maximumStringBytes,
                  model.lastUsedAt.utf8.count <= maximumStringBytes,
                  seen.insert(model.ref).inserted else { continue }
            admitted.append(model)
        }
        return admitted
    }
}

struct ModelCatalogAccumulator {
    private(set) var models: [ModelSummary] = []
    private(set) var rejection: String?
    private var identities = Set<ModelRef>()
    private var pageCount = 0
    private var stringBytes = 0

    mutating func append(_ page: [ModelSummary], hasNextPage: Bool) throws {
        guard pageCount < ModelCatalogPolicy.maximumPages,
              !(hasNextPage && pageCount + 1 == ModelCatalogPolicy.maximumPages),
              page.count <= ModelCatalogPolicy.requestPageSize,
              page.count <= ModelCatalogPolicy.maximumItems - models.count else {
            throw invalidPagination(reason: "page_bounds", path: "models")
        }
        var pageIdentities = Set<ModelRef>()
        var pageStringBytes = 0
        for (index, model) in page.enumerated() {
            let path = "models[\(index)]"
            guard pageIdentities.insert(model.ref).inserted, !identities.contains(model.ref) else {
                throw invalidPagination(reason: "duplicate_identity", path: path)
            }
            let minimum = model.virtual == true ? 0 : 1
            guard model.contextWindow >= minimum else {
                throw invalidPagination(reason: "invalid_token_limit", path: "\(path).contextWindow")
            }
            guard model.maxTokens >= minimum else {
                throw invalidPagination(reason: "invalid_token_limit", path: "\(path).maxTokens")
            }
            guard model.contextWindowLimits?.isValid != false else {
                throw invalidPagination(reason: "invalid_context_limits", path: "\(path).contextWindowLimits")
            }
            guard let bytes = Self.stringByteCount(model), bytes <= Int.max - pageStringBytes else {
                throw invalidPagination(reason: "string_bytes", path: path)
            }
            pageStringBytes += bytes
        }
        guard ModelCatalogPolicy.admitsStringBytes(
            current: stringBytes,
            candidate: pageStringBytes
        ) else { throw invalidPagination(reason: "string_bytes", path: "models") }
        identities.formUnion(pageIdentities)
        models.append(contentsOf: page)
        pageCount += 1
        stringBytes += pageStringBytes
    }

    private static func stringByteCount(_ model: ModelSummary) -> Int? {
        var total = 0
        for value in [model.provider, model.id, model.name] + model.input {
            let count = value.utf8.count
            guard count <= Int.max - total else { return nil }
            total += count
        }
        return total
    }

    private mutating func invalidPagination(reason: String, path: String) -> GatewayFailure {
        rejection = "page=\(pageCount + 1) path=\(path) reason=\(reason)"
        return GatewayFailure(
            code: "invalid_pagination",
            message: "Tron returned an invalid or oversized model catalog.",
            retryable: true,
            details: nil
        )
    }
}

@MainActor
@Observable
final class ProviderAuthCoordinator {
    private struct ProviderParams: Codable { let sessionId: String? }
    private struct ModelParams: Codable { let sessionId: String?; let cursor: String?; let limit: Int }
    private struct ProviderResponse: Decodable { let providers: [ProviderSummary] }
    private struct ModelResponse: Decodable { let models: [ModelSummary]; let nextCursor: String? }
    private struct RecentModelsResponse: Decodable { let models: [RecentModelRef] }
    private struct RecentModelsParams: Codable { }
    private struct BeginParams: Codable {
        let providerId, authType: String
        let sessionId: String?
        let commandId: String
        let replaceOperationId: String?
    }
    private struct BeginResponse: Decodable { let operationId: String; let recovered: Bool? }
    private struct RespondParams: Codable { let operationId, promptId, value: String }
    private struct RespondResponse: Decodable { let answered: Bool }
    private struct CallbackParams: Codable { let operationId, callbackId, query: String }
    private struct CallbackResponse: Decodable { let forwarded: Bool }
    private struct ResumeParams: Codable { let operationId: String }
    private struct ResumeResponse: Decodable { let state, operationId, providerId: String; let success: Bool? }
    private struct CancelParams: Codable { let operationId: String }
    private struct CancelResponse: Decodable { let cancelled: Bool }
    private struct RefreshParams: Codable { let force: Bool; let sessionId: String?; let commandId: String }
    private struct RefreshResponse: Codable { let aborted: Bool; let errors: [String: String] }
    private struct LogoutParams: Codable { let providerId, commandId: String; let sessionId: String? }
    private struct LogoutResponse: Codable { let loggedOut: Bool }

    private struct CatalogAdmission: Equatable {
        let profileGeneration: Int
        let target: ProviderCatalogTarget
        let targetGeneration: Int
    }

    private struct AuthCompletion {
        let operationID: String
        let success: Bool?
        let error: String?
    }

    private struct QuarantinedPresentation {
        var prompt: ProviderAuthPromptState?
        var event: ProviderAuthEventState?
        var completion: AuthCompletion?

        var retainedByteCount: Int {
            (prompt.map(Self.retainedByteCount) ?? 0)
                + (event.map(Self.retainedByteCount) ?? 0)
                + (completion.map { $0.operationID.utf8.count + ($0.error?.utf8.count ?? 0) } ?? 0)
        }

        var retainedElementCount: Int {
            (prompt.map { 1 + $0.options.count } ?? 0)
                + (event.map { 1 + $0.links.count } ?? 0)
                + (completion == nil ? 0 : 1)
        }

        private static func retainedByteCount(_ prompt: ProviderAuthPromptState) -> Int {
            prompt.id.utf8.count
                + prompt.operationId.utf8.count
                + prompt.message.utf8.count
                + (prompt.placeholder?.utf8.count ?? 0)
                + prompt.options.reduce(0) {
                    $0 + $1.id.utf8.count + $1.label.utf8.count + ($1.description?.utf8.count ?? 0)
                }
        }

        private static func retainedByteCount(_ event: ProviderAuthEventState) -> Int {
            event.operationId.utf8.count
                + (event.message?.utf8.count ?? 0)
                + event.links.reduce(0) {
                    $0 + $1.url.absoluteString.utf8.count + ($1.label?.utf8.count ?? 0)
                }
                + (event.url?.absoluteString.utf8.count ?? 0)
                + (event.instructions?.utf8.count ?? 0)
                + (event.userCode?.utf8.count ?? 0)
                + (event.verificationURL?.absoluteString.utf8.count ?? 0)
        }
    }

    private static let maximumQuarantinedOperations = 4
    private static let maximumQuarantinedElements = 64
    private static let maximumQuarantinedBytes = 16 * 1_024

    private let client: GatewayClient
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource

    weak var delegate: (any ProviderAuthCoordinatorDelegate)?

    private var catalogByTarget: [ProviderCatalogTarget: ProviderCatalog] = [:]
    private var loadGenerationByTarget: [ProviderCatalogTarget: Int] = [:]
    private(set) var recentModels: [RecentModelRef] = []
    private var recentModelsLoadGeneration = 0
    private var targetByAuthOperation: [String: ProviderCatalogTarget] = [:]
    private var providerByAuthOperation: [String: String] = [:]
    private var authTypeByAuthOperation: [String: String] = [:]
    private var activeAuthOperationID: String?
    private var recoveredAuthOperationID: String?
    private var pendingCancellationOperationIDs: [String] = []
    private static let maximumPendingCancellations = 4
    private var answeringPromptID: String?
    private var pendingBrowserCallbackByOperation: [String: ProviderOAuthCapturedCallback] = [:]
    private var submittingBrowserCallbackOperationID: String?
    private var authBeginGeneration = 0
    private var authPresentationGeneration = 0
    private var inFlightAuthBeginGenerations = Set<Int>()
    private var quarantinedPresentationByOperation: [String: QuarantinedPresentation] = [:]
    private var quarantinedOperationOrder: [String] = []
    private var profileGeneration = 0
    private struct PreparedCompletion {
        let completion: AuthCompletion
        let profileGeneration: Int
        let presentationGeneration: Int
        let wasActive: Bool
        let target: ProviderCatalogTarget?
    }
    private var pendingCompletionRefresh: PreparedCompletion?
    private var completionRefreshTask: Task<Void, Never>?
    private var completionRefreshGeneration = 0

    private(set) var invalidationGeneration = 0
    private struct PromptInputDraft {
        let operationID: String
        let promptID: String
        let value: String
    }
    private var promptInputDraft: PromptInputDraft?
    private(set) var prompt: ProviderAuthPromptState? {
        didSet {
            if promptInputDraft?.operationID != prompt?.operationId || promptInputDraft?.promptID != prompt?.id {
                promptInputDraft = nil
            }
        }
    }

    func promptInput(for presented: ProviderAuthPromptState) -> String {
        guard activeAuthOperationID == presented.operationId, prompt == presented,
              promptInputDraft?.operationID == presented.operationId,
              promptInputDraft?.promptID == presented.id else { return "" }
        return promptInputDraft?.value ?? ""
    }

    func setPromptInput(_ value: String, for presented: ProviderAuthPromptState) {
        guard activeAuthOperationID == presented.operationId, prompt == presented else { return }
        promptInputDraft = value.isEmpty ? nil : PromptInputDraft(operationID: presented.operationId, promptID: presented.id, value: value)
    }

    private func clearPromptInput(operationID: String) {
        if promptInputDraft?.operationID == operationID { promptInputDraft = nil }
    }

    func isAuthOperationActive(_ operationID: String) -> Bool { activeAuthOperationID == operationID }
    private(set) var event: ProviderAuthEventState?

    init(
        client: GatewayClient,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource
    ) {
        self.client = client
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }
}

extension ProviderAuthCoordinator {
    func catalog(for target: ProviderCatalogTarget) -> ProviderCatalog? {
        catalogByTarget[target]
    }

    func loadRecentModels() async {
        let admittedProfileGeneration = profileGeneration
        let admittedLoadGeneration = recentModelsLoadGeneration
        do {
            let response: RecentModelsResponse = try await client.request(
                "model.recent",
                RecentModelsParams()
            )
            guard profileGeneration == admittedProfileGeneration,
                  recentModelsLoadGeneration == admittedLoadGeneration else { return }
            let admitted = RecentModelCatalogPolicy.admit(response.models)
            if admitted != recentModels { recentModels = admitted }
        } catch is CancellationError {
        } catch {
        }
    }

    func noteRecentModelsChanged() {
        recentModelsLoadGeneration &+= 1
        Task { await loadRecentModels() }
    }

    var activeRecoveredOperationID: String? {
        guard let activeAuthOperationID, recoveredAuthOperationID == activeAuthOperationID else { return nil }
        return activeAuthOperationID
    }

    func activeOperationID(providerID: String, target: ProviderCatalogTarget) -> String? {
        guard let operationID = activeAuthOperationID,
              providerByAuthOperation[operationID] == providerID,
              targetByAuthOperation[operationID] == target else { return nil }
        return operationID
    }

    func activeAuthType(providerID: String, target: ProviderCatalogTarget) -> String? {
        activeOperationID(providerID: providerID, target: target).flatMap { authTypeByAuthOperation[$0] }
    }

    func preferredAvailableModel(for target: ProviderCatalogTarget) -> ModelRef? {
        let available = catalog(for: target)?.models.filter(\.available) ?? []
        return available.first?.ref
    }

    @discardableResult
    func refreshCatalog(target: ProviderCatalogTarget, reportErrors: Bool = true) async -> Bool {
        guard !Task.isCancelled else { return false }
        let admission = beginCatalogLoad(target: target)
        var accumulator = ModelCatalogAccumulator()
        do {
            async let providerRequest: ProviderResponse = client.request(
                "provider.list",
                ProviderParams(sessionId: target.sessionID)
            )
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let response: ModelResponse = try await client.request(
                    "model.list",
                    ModelParams(
                        sessionId: target.sessionID,
                        cursor: cursor,
                        limit: ModelCatalogPolicy.requestPageSize
                    )
                )
                guard admits(admission) else { return false }
                try accumulator.append(response.models, hasNextPage: response.nextCursor != nil)
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw GatewayFailure(
                        code: "invalid_pagination",
                        message: "Tron returned a repeated model cursor.",
                        retryable: true,
                        details: nil
                    )
                }
            } while cursor != nil
            let providers = try await providerRequest.providers
            guard admits(admission) else { return false }
            try ProviderCatalogPolicy.validate(providers)
            catalogByTarget[target] = ProviderCatalog(providers: providers, models: accumulator.models)
            if recentModels.isEmpty { Task { await loadRecentModels() } }
            return true
        } catch {
            guard admits(admission) else { return false }
            if let rejection = accumulator.rejection {
                await AppLog.shared.recordCausal(name: "model.catalog.rejected", outcome: "failure", details: rejection)
                guard admits(admission) else { return false }
            }
            if reportErrors { delegate?.providerAuthCoordinatorSurface(error) }
            return false
        }
    }

    func beginAuth(
        providerID: String,
        authType: String,
        target: ProviderCatalogTarget,
        replacing replacedOperationID: String? = nil
    ) async throws {
        let admittedProfileGeneration = profileGeneration
        authBeginGeneration &+= 1
        let admittedBeginGeneration = authBeginGeneration
        inFlightAuthBeginGenerations.insert(admittedBeginGeneration)
        defer { finishAuthBegin(admittedBeginGeneration) }
        authPresentationGeneration &+= 1
        let response: BeginResponse = try await client.request(
            "auth.begin",
            BeginParams(
                providerId: providerID,
                authType: authType,
                sessionId: target.sessionID,
                commandId: uuidSource.next().uuidString,
                replaceOperationId: replacedOperationID
            )
        )
        try requireProfile(admittedProfileGeneration)
        targetByAuthOperation[response.operationId] = target
        providerByAuthOperation[response.operationId] = providerID
        authTypeByAuthOperation[response.operationId] = authType
        let quarantined = takeQuarantinedPresentation(for: response.operationId)
        guard authBeginGeneration == admittedBeginGeneration else {
            if let completion = quarantined?.completion {
                await processCompletion(completion)
            }
            throw CancellationError()
        }
        activeAuthOperationID = response.operationId
        recoveredAuthOperationID = response.recovered == true ? response.operationId : nil
        prompt = nil
        event = ProviderAuthEventState(
            operationId: response.operationId,
            kind: .progress,
            message: response.recovered == true ? "Resuming provider login…" : "Starting provider login…",
            links: [],
            url: nil,
            instructions: nil,
            userCode: nil,
            verificationURL: nil,
            intervalSeconds: nil,
            expiresInSeconds: nil,
            callbackCapture: nil
        )
        prompt = quarantined?.prompt
        event = quarantined?.event ?? event
        if let completion = quarantined?.completion {
            await processCompletion(completion)
            try requireProfile(admittedProfileGeneration)
            guard authBeginGeneration == admittedBeginGeneration else { throw CancellationError() }
        }
    }

    func beginMCPAuthAdmission() -> Int {
        authBeginGeneration &+= 1
        let generation = authBeginGeneration
        inFlightAuthBeginGenerations.insert(generation)
        return generation
    }

    func adoptMCPAuthOperation(operationID: String, target: ProviderCatalogTarget, admission: Int) {
        authPresentationGeneration &+= 1
        targetByAuthOperation[operationID] = target
        activeAuthOperationID = operationID
        recoveredAuthOperationID = nil
        prompt = nil
        let quarantined = takeQuarantinedPresentation(for: operationID)
        event = quarantined?.event ?? ProviderAuthEventState(
            operationId: operationID,
            kind: .progress,
            message: "Waiting for the MCP server's sign-in request…",
            links: [],
            url: nil,
            instructions: nil,
            userCode: nil,
            verificationURL: nil,
            intervalSeconds: nil,
            expiresInSeconds: nil,
            callbackCapture: nil
        )
        prompt = quarantined?.prompt
        if let completion = quarantined?.completion {
            Task { await processCompletion(completion) }
        }
        finishAuthBegin(admission)
    }

    func finishMCPAuthAdmission(_ admission: Int) {
        finishAuthBegin(admission)
    }

    func finishMCPAuthOperation(operationID: String) {
        retireAuthPresentation(operationID: operationID)
    }

    func restartAuth(operationID: String) async throws {
        guard operationID == activeAuthOperationID,
              let providerID = providerByAuthOperation[operationID],
              let target = targetByAuthOperation[operationID],
              let authType = authTypeByAuthOperation[operationID] else { return }
        try await beginAuth(providerID: providerID, authType: authType, target: target, replacing: operationID)
    }

    func answerAuth(_ value: String) async throws {
        guard let admittedPrompt = prompt,
              answeringPromptID != admittedPrompt.id else { return }
        answeringPromptID = admittedPrompt.id
        defer {
            if answeringPromptID == admittedPrompt.id { answeringPromptID = nil }
        }
        let admittedProfileGeneration = profileGeneration
        let response: RespondResponse
        do {
            response = try await client.request(
                "auth.respond",
                RespondParams(
                    operationId: admittedPrompt.operationId,
                    promptId: admittedPrompt.id,
                    value: value
                )
            )
        } catch let failure as GatewayFailure where failure.code == "not_found" {
            guard profileGeneration == admittedProfileGeneration else { return }
            retireAuthPresentation(operationID: admittedPrompt.operationId)
            return
        }
        try requireProfile(admittedProfileGeneration)
        guard response.answered else {
            if prompt?.operationId == admittedPrompt.operationId, prompt?.id == admittedPrompt.id {
                prompt = nil
            }
            return
        }
        if prompt?.operationId == admittedPrompt.operationId, prompt?.id == admittedPrompt.id {
            prompt = nil
        }
        installCompletingEvent(operationID: admittedPrompt.operationId)
        pendingBrowserCallbackByOperation[admittedPrompt.operationId] = nil
        if submittingBrowserCallbackOperationID == admittedPrompt.operationId {
            submittingBrowserCallbackOperationID = nil
        }
    }

    func submitBrowserCallback(
        _ callback: ProviderOAuthCapturedCallback,
        operationID: String
    ) async throws {
        guard activeAuthOperationID == operationID else { throw CancellationError() }
        guard callback.url.absoluteString.utf8.count <= 16 * 1_024,
              callback.percentEncodedQuery.utf8.count <= 16 * 1_024 else {
            throw GatewayFailure(
                code: "invalid_callback",
                message: "The provider returned an oversized authorization callback.",
                retryable: false,
                details: nil
            )
        }
        pendingBrowserCallbackByOperation[operationID] = callback
        do {
            try await submitPendingBrowserCallback(operationID: operationID)
        } catch let failure as GatewayFailure where failure.retryable {
            return
        } catch is GatewayPossiblySentError {
            return
        } catch is CancellationError {
            guard activeAuthOperationID == operationID else { throw CancellationError() }
        }
    }

    func resumeAuthIfNeeded() async {
        await retryPendingCancellations()
        guard let operationID = activeAuthOperationID else { return }
        do {
            let response: ResumeResponse = try await client.request(
                "auth.resume",
                ResumeParams(operationId: operationID)
            )
            guard response.operationId == operationID else { return }
            if response.state != "active" && activeAuthOperationID == operationID {
                retireAuthPresentation(operationID: operationID)
                return
            }
            try? await submitPendingBrowserCallback(operationID: operationID)
        } catch let failure as GatewayFailure where failure.code == "not_found" {
            retireAuthPresentation(operationID: operationID)
        } catch {
        }
    }

    private func submitPendingBrowserCallback(operationID: String) async throws {
        guard submittingBrowserCallbackOperationID != operationID,
              let callback = pendingBrowserCallbackByOperation[operationID],
              activeAuthOperationID == operationID else { return }
        submittingBrowserCallbackOperationID = operationID
        defer {
            if submittingBrowserCallbackOperationID == operationID {
                submittingBrowserCallbackOperationID = nil
            }
        }
        if let prompt,
           prompt.operationId == operationID,
           prompt.kind == .manualCode {
            try await answerAuth(callback.url.absoluteString)
            pendingBrowserCallbackByOperation[operationID] = nil
            return
        }
        guard let event,
              event.operationId == operationID,
              let capture = event.callbackCapture else { return }
        let response: CallbackResponse = try await client.request(
            "auth.callback",
            CallbackParams(
                operationId: operationID,
                callbackId: capture.id,
                query: callback.percentEncodedQuery
            )
        )
        if response.forwarded || activeAuthOperationID != operationID {
            pendingBrowserCallbackByOperation[operationID] = nil
            installCompletingEvent(operationID: operationID)
        }
    }

    private func installCompletingEvent(operationID: String) {
        guard activeAuthOperationID == operationID else { return }
        event = ProviderAuthEventState(
            operationId: operationID,
            kind: .progress,
            message: "Completing provider login…",
            links: [],
            url: nil,
            instructions: nil,
            userCode: nil,
            verificationURL: nil,
            intervalSeconds: nil,
            expiresInSeconds: nil,
            callbackCapture: nil
        )
    }

    func cancelAuth(operationID: String? = nil) async {
        guard let id = operationID ?? prompt?.operationId ?? event?.operationId else { return }
        let admittedProfileGeneration = profileGeneration
        let response: CancelResponse?
        var acknowledged = true
        do {
            response = try await client.request("auth.cancel", CancelParams(operationId: id))
        } catch let failure as GatewayFailure where !failure.retryable {
            response = nil
        } catch {
            response = nil
            acknowledged = false
        }
        guard profileGeneration == admittedProfileGeneration else { return }
        if !acknowledged { recordPendingCancellation(id) }
        clearPromptInput(operationID: id)
        if activeAuthOperationID == id {
            activeAuthOperationID = nil
            authPresentationGeneration &+= 1
        }
        if prompt?.operationId == id { prompt = nil }
        if event?.operationId == id { event = nil }
        pendingBrowserCallbackByOperation[id] = nil
        if submittingBrowserCallbackOperationID == id { submittingBrowserCallbackOperationID = nil }
        if response?.cancelled == true {
            targetByAuthOperation[id] = nil
            providerByAuthOperation[id] = nil
            authTypeByAuthOperation[id] = nil
        }
    }

    private func recordPendingCancellation(_ operationID: String) {
        pendingCancellationOperationIDs.removeAll { $0 == operationID }
        pendingCancellationOperationIDs.append(operationID)
        if pendingCancellationOperationIDs.count > Self.maximumPendingCancellations {
            pendingCancellationOperationIDs.removeFirst()
        }
    }

    private func retryPendingCancellations() async {
        let admittedProfileGeneration = profileGeneration
        for operationID in pendingCancellationOperationIDs {
            do {
                let _: CancelResponse = try await client.request("auth.cancel", CancelParams(operationId: operationID))
            } catch let failure as GatewayFailure where !failure.retryable {
            } catch {
                return
            }
            guard profileGeneration == admittedProfileGeneration else { return }
            pendingCancellationOperationIDs.removeAll { $0 == operationID }
        }
    }

    func refreshModelCatalog(target: ProviderCatalogTarget, force: Bool = true) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        let params = RefreshParams(force: force, sessionId: target.sessionID, commandId: commandID)
        let response: RefreshResponse = try await mutationExecutor.perform(
            method: "models.refresh",
            commandID: commandID
        ) {
            try await client.request("models.refresh", params, timeout: GatewayRequestTimeout.modelCatalogRefresh)
        }
        try requireProfile(admittedProfileGeneration)
        _ = await refreshCatalog(target: target)
        try requireProfile(admittedProfileGeneration)
        if response.aborted {
            throw GatewayFailure(
                code: "model_catalog_refresh_timeout",
                message: "Model catalog refresh timed out. Existing models remain available.",
                retryable: true,
                details: nil
            )
        }
        if !response.errors.isEmpty {
            throw GatewayFailure(
                code: "model_catalog_refresh_failed",
                message: "One or more model providers could not be refreshed. Existing models remain available.",
                retryable: true,
                details: nil
            )
        }
    }

    func logout(providerID: String, target: ProviderCatalogTarget) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        let params = LogoutParams(providerId: providerID, commandId: commandID, sessionId: target.sessionID)
        let _: LogoutResponse = try await mutationExecutor.perform(method: "auth.logout", commandID: commandID) {
            try await client.request("auth.logout", params)
        }
        try requireProfile(admittedProfileGeneration)
        _ = await refreshCatalog(target: target)
        try requireProfile(admittedProfileGeneration)
    }

    func handlePrompt(_ payload: JSONValue) {
        guard let parsed = parsePrompt(payload) else { return }
        if parsed.operationId == activeAuthOperationID {
            prompt = parsed
            if parsed.kind == .manualCode,
               pendingBrowserCallbackByOperation[parsed.operationId] != nil {
                Task { [weak self] in
                    try? await self?.submitPendingBrowserCallback(operationID: parsed.operationId)
                }
            }
        } else if targetByAuthOperation[parsed.operationId] == nil,
                  !inFlightAuthBeginGenerations.isEmpty {
            quarantine(prompt: parsed)
        }
    }

    func handleEvent(_ payload: JSONValue) {
        guard let parsed = parseEvent(payload) else { return }
        if parsed.operationId == activeAuthOperationID {
            event = parsed
        } else if targetByAuthOperation[parsed.operationId] == nil,
                  !inFlightAuthBeginGenerations.isEmpty {
            quarantine(event: parsed)
        }
    }

    func dispatchCompletion(_ payload: JSONValue) {
        guard let completion = parseCompletion(payload) else { return }
        guard activeAuthOperationID == completion.operationID
                || targetByAuthOperation[completion.operationID] != nil else {
            if !inFlightAuthBeginGenerations.isEmpty { quarantine(completion: completion) }
            return
        }
        let prepared = prepareCompletion(completion)
        invalidationGeneration &+= 1
        if prepared.wasActive || pendingCompletionRefresh == nil {
            pendingCompletionRefresh = prepared
        }
        guard completionRefreshTask == nil else { return }
        completionRefreshGeneration &+= 1
        let generation = completionRefreshGeneration
        completionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.completionRefreshGeneration == generation { self.completionRefreshTask = nil } }
            while !Task.isCancelled, self.completionRefreshGeneration == generation,
                  let pending = self.pendingCompletionRefresh {
                self.pendingCompletionRefresh = nil
                await self.finishCompletion(pending)
            }
        }
    }

    func noteProvidersChanged() {
        invalidationGeneration &+= 1
    }

    func noteModelCatalogChanged() {
        for target in Array(catalogByTarget.keys) {
            Task { await refreshCatalog(target: target, reportErrors: false) }
        }
    }

    func retireConnection() {
        let retainedInput = promptInputDraft
        revokeConnectionOwnership(clearCatalogs: false, preserveActiveAuth: true)
        if let retainedInput, retainedInput.operationID == activeAuthOperationID {
            promptInputDraft = retainedInput
        }
    }

    func clearProfile() {
        revokeConnectionOwnership(clearCatalogs: true, preserveActiveAuth: false)
    }

    private func revokeConnectionOwnership(clearCatalogs: Bool, preserveActiveAuth: Bool) {
        completionRefreshGeneration &+= 1
        completionRefreshTask?.cancel()
        completionRefreshTask = nil
        pendingCompletionRefresh = nil
        profileGeneration &+= 1
        invalidationGeneration &+= 1
        authBeginGeneration &+= 1
        authPresentationGeneration &+= 1
        loadGenerationByTarget = loadGenerationByTarget.mapValues { $0 &+ 1 }
        recentModelsLoadGeneration &+= 1
        if clearCatalogs {
            catalogByTarget.removeAll()
            recentModels.removeAll()
            pendingCancellationOperationIDs.removeAll()
        }
        if preserveActiveAuth, let activeAuthOperationID {
            targetByAuthOperation = targetByAuthOperation.filter { $0.key == activeAuthOperationID }
            providerByAuthOperation = providerByAuthOperation.filter { $0.key == activeAuthOperationID }
            authTypeByAuthOperation = authTypeByAuthOperation.filter { $0.key == activeAuthOperationID }
        } else {
            targetByAuthOperation.removeAll()
            providerByAuthOperation.removeAll()
            authTypeByAuthOperation.removeAll()
            activeAuthOperationID = nil
            recoveredAuthOperationID = nil
            pendingBrowserCallbackByOperation.removeAll()
            event = nil
        }
        answeringPromptID = nil
        submittingBrowserCallbackOperationID = nil
        inFlightAuthBeginGenerations.removeAll()
        removeAllQuarantinedPresentations()
        prompt = nil
    }

    private func retireAuthPresentation(operationID: String) {
        clearPromptInput(operationID: operationID)
        targetByAuthOperation[operationID] = nil
        providerByAuthOperation[operationID] = nil
        authTypeByAuthOperation[operationID] = nil
        if activeAuthOperationID == operationID {
            activeAuthOperationID = nil
            authPresentationGeneration &+= 1
        }
        if prompt?.operationId == operationID { prompt = nil }
        if event?.operationId == operationID { event = nil }
        pendingBrowserCallbackByOperation[operationID] = nil
        if submittingBrowserCallbackOperationID == operationID {
            submittingBrowserCallbackOperationID = nil
        }
    }

    private func parsePrompt(_ payload: JSONValue) -> ProviderAuthPromptState? {
        guard let root = payload.objectValue,
              let operationID = root["operationId"]?.stringValue,
              let promptID = root["promptId"]?.stringValue,
              let promptValue = root["prompt"]?.objectValue,
              let rawKind = promptValue["type"]?.stringValue,
              let kind = ProviderAuthPromptState.Kind(rawValue: rawKind),
              let message = promptValue["message"]?.stringValue else { return nil }
        let options = (promptValue["options"]?.arrayValue ?? []).compactMap { value -> ProviderAuthPromptState.Option? in
            guard let item = value.objectValue,
                  let id = item["id"]?.stringValue,
                  let label = item["label"]?.stringValue else { return nil }
            return .init(id: id, label: label, description: item["description"]?.stringValue)
        }
        return ProviderAuthPromptState(
            id: promptID,
            operationId: operationID,
            kind: kind,
            message: message,
            placeholder: promptValue["placeholder"]?.stringValue,
            options: options
        )
    }

    private func parseEvent(_ payload: JSONValue) -> ProviderAuthEventState? {
        guard let root = payload.objectValue,
              let operationID = root["operationId"]?.stringValue,
              let eventValue = root["event"]?.objectValue,
              let rawKind = eventValue["type"]?.stringValue,
              let kind = ProviderAuthEventState.Kind(rawValue: rawKind) else { return nil }
        let links = (eventValue["links"]?.arrayValue ?? []).compactMap { value -> ProviderAuthEventState.Link? in
            guard let object = value.objectValue,
                  let rawURL = object["url"]?.stringValue,
                  let url = URL(string: rawURL),
                  ProviderOAuthURLPolicy.admitsExternalWebURL(url) else { return nil }
            return .init(url: url, label: object["label"]?.stringValue)
        }
        let callbackCapture: ProviderOAuthCallbackCapture?
        if let capture = root["callbackCapture"]?.objectValue,
           let id = capture["id"]?.stringValue,
           let host = capture["host"]?.stringValue,
           let port = capture["port"]?.intValue,
           let path = capture["path"]?.stringValue,
           let boundedPort = UInt16(exactly: port),
           ProviderOAuthURLPolicy.normalizedLoopbackHost(host) == host,
           id.utf8.count <= 100,
           path.hasPrefix("/"), path.utf8.count <= 2_048 {
            callbackCapture = ProviderOAuthCallbackCapture(id: id, host: host, port: boundedPort, path: path)
        } else {
            callbackCapture = nil
        }
        let authorizationURL = eventValue["url"]?.stringValue
            .flatMap(URL.init(string:))
            .flatMap { ProviderOAuthURLPolicy.admitsExternalWebURL($0) ? $0 : nil }
        let verificationURL = eventValue["verificationUri"]?.stringValue
            .flatMap(URL.init(string:))
            .flatMap { ProviderOAuthURLPolicy.admitsExternalWebURL($0) ? $0 : nil }
        return ProviderAuthEventState(
            operationId: operationID,
            kind: kind,
            message: eventValue["message"]?.stringValue,
            links: links,
            url: authorizationURL,
            instructions: eventValue["instructions"]?.stringValue,
            userCode: eventValue["userCode"]?.stringValue,
            verificationURL: verificationURL,
            intervalSeconds: eventValue["intervalSeconds"]?.intValue,
            expiresInSeconds: eventValue["expiresInSeconds"]?.intValue,
            callbackCapture: callbackCapture
        )
    }

    private func parseCompletion(_ payload: JSONValue) -> AuthCompletion? {
        guard let root = payload.objectValue,
              let operationID = root["operationId"]?.stringValue else { return nil }
        return AuthCompletion(
            operationID: operationID,
            success: root["success"]?.boolValue,
            error: root["error"]?.stringValue
        )
    }

    private func processCompletion(_ completion: AuthCompletion) async {
        await finishCompletion(prepareCompletion(completion))
    }

    private func prepareCompletion(_ completion: AuthCompletion) -> PreparedCompletion {
        let admittedProfileGeneration = profileGeneration
        let admittedPresentationGeneration = authPresentationGeneration
        let wasActiveOperation = activeAuthOperationID == completion.operationID
        clearPromptInput(operationID: completion.operationID)
        if wasActiveOperation {
            activeAuthOperationID = nil
            if prompt?.operationId == completion.operationID { prompt = nil }
            if event?.operationId == completion.operationID { event = nil }
        }
        pendingBrowserCallbackByOperation[completion.operationID] = nil
        if submittingBrowserCallbackOperationID == completion.operationID {
            submittingBrowserCallbackOperationID = nil
        }
        let target = targetByAuthOperation.removeValue(forKey: completion.operationID)
        providerByAuthOperation[completion.operationID] = nil
        return PreparedCompletion(completion: completion, profileGeneration: admittedProfileGeneration,
                                  presentationGeneration: admittedPresentationGeneration, wasActive: wasActiveOperation, target: target)
    }

    private func finishCompletion(_ prepared: PreparedCompletion) async {
        guard !Task.isCancelled, profileGeneration == prepared.profileGeneration else { return }
        if let target = prepared.target { _ = await refreshCatalog(target: target) }
        guard !Task.isCancelled, prepared.wasActive,
              profileGeneration == prepared.profileGeneration,
              authPresentationGeneration == prepared.presentationGeneration else { return }
        if prepared.completion.success == false {
            delegate?.providerAuthCoordinatorSetCompletionError(prepared.completion.error)
        }
    }

    private func finishAuthBegin(_ generation: Int) {
        inFlightAuthBeginGenerations.remove(generation)
        if inFlightAuthBeginGenerations.isEmpty {
            removeAllQuarantinedPresentations()
        }
    }

    private func quarantine(prompt: ProviderAuthPromptState) {
        var presentation = quarantinedPresentationByOperation[prompt.operationId] ?? QuarantinedPresentation()
        presentation.prompt = prompt
        retainQuarantinedPresentation(presentation, for: prompt.operationId)
    }

    private func quarantine(event: ProviderAuthEventState) {
        var presentation = quarantinedPresentationByOperation[event.operationId] ?? QuarantinedPresentation()
        presentation.event = event
        retainQuarantinedPresentation(presentation, for: event.operationId)
    }

    private func quarantine(completion: AuthCompletion) {
        var presentation = quarantinedPresentationByOperation[completion.operationID] ?? QuarantinedPresentation()
        presentation.completion = completion
        retainQuarantinedPresentation(presentation, for: completion.operationID)
    }

    private func retainQuarantinedPresentation(
        _ presentation: QuarantinedPresentation,
        for operationID: String
    ) {
        guard presentation.retainedElementCount <= Self.maximumQuarantinedElements,
              presentation.retainedByteCount <= Self.maximumQuarantinedBytes else {
            discardQuarantinedPresentation(for: operationID)
            return
        }
        if quarantinedPresentationByOperation[operationID] == nil {
            quarantinedOperationOrder.append(operationID)
        }
        quarantinedPresentationByOperation[operationID] = presentation
        while quarantinedOperationOrder.count > Self.maximumQuarantinedOperations
                || quarantinedElementCount > Self.maximumQuarantinedElements
                || quarantinedByteCount > Self.maximumQuarantinedBytes,
              let oldest = quarantinedOperationOrder.first {
            discardQuarantinedPresentation(for: oldest)
        }
    }

    private var quarantinedByteCount: Int {
        quarantinedPresentationByOperation.values.reduce(0) { $0 + $1.retainedByteCount }
    }

    private var quarantinedElementCount: Int {
        quarantinedPresentationByOperation.values.reduce(0) { $0 + $1.retainedElementCount }
    }

    private func takeQuarantinedPresentation(for operationID: String) -> QuarantinedPresentation? {
        let presentation = quarantinedPresentationByOperation[operationID]
        discardQuarantinedPresentation(for: operationID)
        return presentation
    }

    private func discardQuarantinedPresentation(for operationID: String) {
        quarantinedPresentationByOperation[operationID] = nil
        quarantinedOperationOrder.removeAll { $0 == operationID }
    }

    private func removeAllQuarantinedPresentations() {
        quarantinedPresentationByOperation.removeAll()
        quarantinedOperationOrder.removeAll()
    }

    private func beginCatalogLoad(target: ProviderCatalogTarget) -> CatalogAdmission {
        let generation = (loadGenerationByTarget[target] ?? 0) &+ 1
        loadGenerationByTarget[target] = generation
        return CatalogAdmission(
            profileGeneration: profileGeneration,
            target: target,
            targetGeneration: generation
        )
    }

    private func admits(_ admission: CatalogAdmission) -> Bool {
        !Task.isCancelled && profileGeneration == admission.profileGeneration
            && loadGenerationByTarget[admission.target] == admission.targetGeneration
    }

    private func requireProfile(_ admittedProfileGeneration: Int) throws {
        guard profileGeneration == admittedProfileGeneration else { throw CancellationError() }
    }

    #if HOSTED_TEST
    func installHostedCatalog(_ catalog: ProviderCatalog?, for target: ProviderCatalogTarget) {
        catalogByTarget[target] = catalog
    }

    func installHostedRecentModels(_ models: [RecentModelRef]) {
        recentModelsLoadGeneration &+= 1
        recentModels = RecentModelCatalogPolicy.admit(models)
    }

    #endif
}
