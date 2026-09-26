import Foundation
import Observation

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

    static func shouldCancelOperationWhenProviderSheetDisappears(sceneIsActive: Bool) -> Bool {
        sceneIsActive
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

/// Admission for the Gateway's bounded recent-model history. The Gateway caps
/// its own store; the client bounds again so a malformed or oversized response
/// can never inflate the picker's Recent rail.
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
    private var identities = Set<ModelRef>()
    private var pageCount = 0
    private var stringBytes = 0

    var nextPageNumber: Int { pageCount + 1 }

    mutating func append(_ page: [ModelSummary], hasNextPage: Bool) throws {
        guard pageCount < ModelCatalogPolicy.maximumPages,
              !(hasNextPage && pageCount + 1 == ModelCatalogPolicy.maximumPages),
              page.count <= ModelCatalogPolicy.requestPageSize,
              page.count <= ModelCatalogPolicy.maximumItems - models.count else {
            throw invalidPagination()
        }
        var pageIdentities = Set<ModelRef>()
        var pageStringBytes = 0
        for model in page {
            guard pageIdentities.insert(model.ref).inserted,
                  !identities.contains(model.ref),
                  model.contextWindow > 0,
                  model.maxTokens > 0,
                  model.contextWindowLimits?.isValid != false,
                  let bytes = Self.stringByteCount(model),
                  bytes <= Int.max - pageStringBytes else { throw invalidPagination() }
            pageStringBytes += bytes
        }
        guard ModelCatalogPolicy.admitsStringBytes(
            current: stringBytes,
            candidate: pageStringBytes
        ) else { throw invalidPagination() }
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

    private func invalidPagination() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_pagination",
            message: "Tron returned an invalid or oversized model catalog.",
            retryable: true,
            details: nil
        )
    }
}

/// Owns disposable provider/model projections and operation-keyed provider
/// authentication state. Gateway provider state remains canonical.
@MainActor
@Observable
final class ProviderAuthCoordinator {
    private struct ProviderParams: Codable { let sessionId: String? }
    private struct ModelParams: Codable { let sessionId: String?; let cursor: String?; let limit: Int }
    private struct ProviderResponse: Decodable { let providers: [ProviderSummary] }
    private struct ModelResponse: Decodable { let models: [ModelSummary]; let nextCursor: String? }
    private struct RecentModelsResponse: Decodable { let models: [RecentModelRef] }
    /// `model.recent` is global: it carries no session scope.
    private struct RecentModelsParams: Codable { }
    private struct BeginParams: Codable {
        let providerId, authType: String
        let sessionId: String?
        let commandId: String
        let replaceOperationId: String?
    }
    /// `recovered` is additive: the Gateway recovers the active operation for
    /// the same device/provider/auth-method/target instead of admitting another.
    /// Its absence means a new admission, and Restart is offered only when true.
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
    /// Cancellations whose acknowledgement was lost in transit. They are
    /// retried on reconnect so an explicit Cancel is not silently dropped.
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
    private(set) var prompt: ProviderAuthPromptState?
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

    func catalog(for target: ProviderCatalogTarget) -> ProviderCatalog? {
        catalogByTarget[target]
    }

    /// Reads the Gateway's recent-model history for the current profile.
    /// Auxiliary presentation data: a failure — including a Gateway that
    /// predates `model.recent` — keeps the last projection and surfaces no
    /// error, because the picker's Recent rail must never block selection.
    func loadRecentModels() async {
        let admittedProfileGeneration = profileGeneration
        let admittedLoadGeneration = recentModelsLoadGeneration
        do {
            let response: RecentModelsResponse = try await client.request(
                "model.recent",
                RecentModelsParams(),
                diagnosticPurpose: "recent-models"
            )
            guard profileGeneration == admittedProfileGeneration,
                  recentModelsLoadGeneration == admittedLoadGeneration else { return }
            recentModels = RecentModelCatalogPolicy.admit(response.models)
        } catch is CancellationError {
        } catch {
        }
    }

    /// The Gateway recorded a new recent model. Generation fencing discards a
    /// read that loses the race with this one.
    func noteRecentModelsChanged() {
        recentModelsLoadGeneration &+= 1
        Task { await loadRecentModels() }
    }

    /// The active operation when the Gateway recovered it for a fresh begin, so
    /// the presentation can offer Continue, Restart, or Cancel.
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
        return available.first(where: { $0.provider == "openai-codex" && $0.id == "gpt-5.6-sol" })?.ref
            ?? available.first?.ref
    }

    @discardableResult
    func refreshCatalog(target: ProviderCatalogTarget) async -> Bool {
        guard !Task.isCancelled else { return false }
        let admission = beginCatalogLoad(target: target)
        do {
            async let providerRequest: ProviderResponse = client.request(
                "provider.list",
                ProviderParams(sessionId: target.sessionID)
            )
            var accumulator = ModelCatalogAccumulator()
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let response: ModelResponse = try await client.request(
                    "model.list",
                    ModelParams(
                        sessionId: target.sessionID,
                        cursor: cursor,
                        limit: ModelCatalogPolicy.requestPageSize
                    ),
                    diagnosticPurpose: "provider-model-catalog",
                    diagnosticPage: accumulator.nextPageNumber
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
            return true
        } catch {
            guard admits(admission) else { return false }
            delegate?.providerAuthCoordinatorSurface(error)
            return false
        }
    }

    /// Begins, recovers, or (with `replacing`) restarts one provider login. A
    /// fresh command is safe after an uncertain response: the Gateway recovers
    /// the same-key operation, and a stale replacement ID recovers the successor.
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
        // Beginning a newer operation synchronously revokes any suspended
        // completion's authority to publish an error for the previous UI.
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
        // Retain every operation target admitted by this profile so even a
        // superseded operation can refresh its exact scope when it completes.
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

    /// Explicitly replaces the named active operation with the same provider
    /// method. The Gateway retires it (invalidating its authorization link)
    /// before starting the successor; a stale ID sends nothing.
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
            // A reconnect or transport replacement can retire the broker
            // operation between presenting the prompt and submitting its value.
            // Never surface the broker's misleading operation-not-found popup;
            // retire only this stale presentation and let the provider catalog
            // refresh on the next authoritative connection.
            guard profileGeneration == admittedProfileGeneration else { return }
            retireAuthPresentation(operationID: admittedPrompt.operationId)
            return
        }
        try requireProfile(admittedProfileGeneration)
        guard response.answered else {
            // The Gateway may have already completed or retired this prompt
            // before a duplicate UI submission reached it. Do not turn that
            // benign race into a user-facing operation-not-found error.
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
            // The callback remains memory-only and is retried after auth.resume.
            return
        } catch is GatewayPossiblySentError {
            // The Gateway may already have delivered the one-use callback.
            // Resume first; its latest event/completion decides whether a retry
            // remains admissible.
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
            // Reconnect reconciliation owns the next retry. Keep the bounded
            // operation identity rather than turning transport loss into OAuth
            // cancellation.
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
            // A definite rejection (including an already-retired operation)
            // settles this cancellation; only uncertain delivery is retried.
            response = nil
        } catch {
            response = nil
            acknowledged = false
        }
        guard profileGeneration == admittedProfileGeneration else { return }
        if !acknowledged { recordPendingCancellation(id) }
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
        // The Gateway timeout remains the final bound for an operation whose
        // cancellation this bounded retry list had to drop.
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
        // Pi retains prior provider entries when one network refresh fails. Reload
        // first so successful provider updates and cached fallbacks remain visible.
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

    /// Commit exact terminal ownership before returning to global intake. Only
    /// the optional catalog refresh is deferred, with one worker and one latest
    /// pending active presentation; repeated/unowned events cannot queue tasks.
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

    func handleCompletion(_ payload: JSONValue) async {
        // AuthBroker starts login before the async request dispatcher flushes
        // auth.begin. An already-resolved login can therefore complete first.
        guard let completion = parseCompletion(payload) else { return }
        if activeAuthOperationID == completion.operationID
            || targetByAuthOperation[completion.operationID] != nil {
            await processCompletion(completion)
        } else if !inFlightAuthBeginGenerations.isEmpty {
            quarantine(completion: completion)
        }
    }

    func noteProvidersChanged() {
        invalidationGeneration &+= 1
    }

    /// Revokes disposable transport work while retaining the stable-device-owned
    /// provider operation so a replacement socket can rebind with auth.resume.
    func retireConnection() {
        revokeConnectionOwnership(clearCatalogs: false, preserveActiveAuth: true)
    }

    /// Synchronously revokes suspended work and disposes all profile projections.
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
            // Pending cancellations belong to the retired profile's Gateway.
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

    func setHostedInvalidationGeneration(_ generation: Int) {
        invalidationGeneration = generation
    }

    func hostedTarget(for operationID: String) -> ProviderCatalogTarget? {
        targetByAuthOperation[operationID]
    }

    func installHostedAuthOperation(
        _ operationID: String,
        target: ProviderCatalogTarget,
        providerID: String = "provider",
        authType: String = "oauth",
        active: Bool = true
    ) {
        targetByAuthOperation[operationID] = target
        providerByAuthOperation[operationID] = providerID
        authTypeByAuthOperation[operationID] = authType
        guard active else { return }
        authBeginGeneration &+= 1
        authPresentationGeneration &+= 1
        activeAuthOperationID = operationID
        prompt = nil
        event = nil
    }

    var hostedActiveAuthOperationID: String? { activeAuthOperationID }
    var hostedPendingCancellationOperationIDs: [String] { pendingCancellationOperationIDs }
    var hostedQuarantinedOperationCount: Int { quarantinedPresentationByOperation.count }
    var hostedQuarantinedOperationIDs: [String] { quarantinedOperationOrder }
    var hostedQuarantinedElementCount: Int { quarantinedElementCount }
    var hostedQuarantinedByteCount: Int { quarantinedByteCount }
    #endif
}
