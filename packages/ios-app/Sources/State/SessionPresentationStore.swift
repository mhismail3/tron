import Foundation
import Observation

struct SessionPresentationIdentity: Hashable, Sendable {
    let sessionID: String
    let generation: Int
}

enum SessionSnapshotInstallationMode { case freshPresentation, reconnect }
enum SessionEditorAction: String, Hashable, Sendable { case set, paste, native }

struct GatewaySessionOpenResponse: Decodable {
    let session: SessionSnapshot
    let syncToken: String
    let subscriptionToken: String

    private enum CodingKeys: String, CodingKey { case session, syncToken, subscriptionToken }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionSnapshot.self, forKey: .session)
        guard ExtensionPresentationPolicy.admit(session.extensionPresentation) else {
            throw DecodingError.dataCorruptedError(forKey: .session, in: container, debugDescription: "Invalid extension presentation snapshot")
        }
        syncToken = try container.decode(String.self, forKey: .syncToken)
        subscriptionToken = try container.decode(String.self, forKey: .subscriptionToken)
    }
}

@MainActor
protocol SessionPresentationStoreDelegate: AnyObject {
    func sessionPresentationStoreDidRequestCatalogRefresh()
    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationIdentity,
        action: SessionEditorAction,
        text: String,
        fullText: String,
        revision: Int,
        operationID: String?
    )
    func sessionPresentationStoreDidOpen(_ target: SessionPresentationIdentity)
    func sessionPresentationStorePostNotice(_ message: String, replacing key: GlobalNoticeKey?)
    func sessionPresentationStoreRemoveNotice(_ key: GlobalNoticeKey)
    func sessionPresentationStoreSurface(_ error: Error)
    func sessionPresentationStoreCheckpointCache()
}

@MainActor
@Observable
final class SessionPresentationStore {
    private let client: GatewayClient
    private let performanceSignposts: any PerformanceSignposting
    weak var delegate: (any SessionPresentationStoreDelegate)?

    private(set) var target: SessionPresentationIdentity?
    private var pendingTarget: SessionPresentationIdentity?
    private(set) var snapshot: SessionSnapshot?
    private(set) var chatCanonicalGeneration = 0
    private(set) var chatTimelineGeneration = 0
    private(set) var isAuthoritative = false
    @ObservationIgnored private var authoritativeTailSnapshot: SessionSnapshot?
    @ObservationIgnored private var hasLoadedTranscriptHistory = false
    @ObservationIgnored private var discardLoadedHistoryAfterCurrentLoad = false
    private(set) var loadingEarlierTranscript = false
    private var revokedTargets = Set<SessionPresentationIdentity>()
    private var nextPresentationGeneration = 0
    // Every Gateway connection owns a distinct token namespace. Responses and
    // close completions from an older connection must not mutate new ownership.
    private var connectionGeneration = 0
    private var subscribedSessionID: String?
    private var subscriptionToken: String?
    private var subscriptionTarget: SessionPresentationIdentity?
    private var pendingRebaselines: [String: SessionSnapshot] = [:]
    private let synchronization = SessionSynchronizationCoordinator()
    private var deferredEffectsByTarget: [SessionPresentationIdentity: [ReducerEffect]] = [:]

    private(set) var context: JSONValue?
    private(set) var sessionTree: [SessionTreeNode] = []
    private(set) var commands: [CommandInfo] = []
    private(set) var resources: JSONValue?
    private var structureRevision = 0
    private var contextRevision = 0
    private var resourceRevision = 0
    private var contextLoadGeneration = 0
    private var treeLoadGeneration = 0
    private var commandLoadGeneration = 0
    private var resourceLoadGeneration = 0

    init(
        client: GatewayClient,
        performanceSignposts: any PerformanceSignposting
    ) {
        self.client = client
        self.performanceSignposts = performanceSignposts
    }

    var mountedTarget: SessionPresentationIdentity? {
        guard let target, owns(target) else { return nil }
        return target
    }

    var selectedSessionID: String? { target?.sessionID ?? pendingTarget?.sessionID }

    func authoritativeSnapshot(for sessionID: String) -> SessionSnapshot? {
        guard isAuthoritative, ownsSession(sessionID), snapshot?.sessionId == sessionID else { return nil }
        return snapshot
    }

    var disposableCacheSnapshot: SessionSnapshot? { authoritativeTailSnapshot }

    func snapshotForOwnedSession(_ sessionID: String) -> SessionSnapshot? {
        guard ownsSession(sessionID) else { return nil }
        return snapshot
    }

    func presentationGeneration(for sessionID: String) -> Int? {
        guard target?.sessionID == sessionID else { return nil }
        return target?.generation
    }

    func presentationTarget(for sessionID: String) -> SessionPresentationIdentity? {
        guard target?.sessionID == sessionID else { return nil }
        return target
    }

    func owns(_ requested: SessionPresentationIdentity) -> Bool {
        target == requested && !revokedTargets.contains(requested)
    }

    func revokeIntake(_ requested: SessionPresentationIdentity) {
        guard target == requested else { return }
        revokedTargets.insert(requested)
    }

    func hasInstalledSubscription(for sessionID: String) -> Bool {
        guard let target = mountedTarget else { return false }
        return isAuthoritative
            && target.sessionID == sessionID
            && subscribedSessionID == sessionID
            && subscriptionTarget == target
            && subscriptionToken != nil
    }

    func installedSubscriptionToken(for sessionID: String) -> String? {
        guard hasInstalledSubscription(for: sessionID) else { return nil }
        return subscriptionToken
    }

    func ownsInstalledSubscription(sessionID: String, token: String) -> Bool {
        ownsSubscription(sessionID: sessionID, requestedToken: token)
    }

    func structureRevision(for sessionID: String) -> Int {
        ownsSession(sessionID) ? structureRevision : 0
    }

    func contextRevision(for sessionID: String) -> Int {
        ownsSession(sessionID) ? contextRevision : 0
    }

    func resourceRevision(for sessionID: String) -> Int {
        ownsSession(sessionID) ? resourceRevision : 0
    }

    func open(_ sessionID: String) async throws -> Int {
        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
        let interval = performanceSignposts.begin(.sessionOpen)
        var result = PerformanceResult.failure
        defer {
            if Task.isCancelled { result = .cancelled }
            performanceSignposts.end(interval, result: result, metrics: .none)
        }

        nextPresentationGeneration &+= 1
        let requested = SessionPresentationIdentity(
            sessionID: sessionID,
            generation: nextPresentationGeneration
        )
        pendingTarget = requested
        // A same-session mounted snapshot remains truthful while a replacement
        // owner reconnects. New sessions have no retained chat to preserve.
        let retainsMountedChat = isAuthoritative
            && target?.sessionID == sessionID
            && snapshot?.sessionId == sessionID
        if !retainsMountedChat { isAuthoritative = false }
        var didOpen = false
        defer {
            if !didOpen {
                deferredEffectsByTarget[requested] = nil
                // A failed fresh open must not leave the dashboard believing
                // this exact route is still selected. The live subscription
                // owner is closed by the synchronization failure path.
                if pendingTarget == requested { pendingTarget = nil }
            }
        }
        clearSecondaryProjection()
        if subscribedSessionID != sessionID {
            guard await closeCurrentSubscription() else {
                if pendingTarget == requested { pendingTarget = nil }
                throw GatewayFailure(code: "subscription_close_failed", message: "The previous session is still closing. Please try again.", retryable: true, details: nil)
            }
        }
        guard pendingTarget == requested else { throw CancellationError() }
        let synchronized = await synchronize(
            sessionID,
            replacingVisibleTranscript: true,
            presentationGeneration: requested.generation
        )
        guard pendingTarget == requested,
              synchronized,
              subscribedSessionID == sessionID,
              subscriptionTarget == requested else {
            throw GatewayFailure(code: "sync_failed", message: "Tron could not synchronize this session.", retryable: true, details: nil)
        }
        target = requested
        pendingTarget = nil
        revokedTargets.remove(requested)
        isAuthoritative = true
        // Composer presentation authority must mount before deferred editor
        // effects publish for this exact fresh presentation.
        delegate?.sessionPresentationStoreDidOpen(requested)
        publish(deferredEffectsByTarget.removeValue(forKey: requested) ?? [], target: requested)
        didOpen = true
        result = .success
        return requested.generation
    }

    func close(_ requested: SessionPresentationIdentity) async {
        revokedTargets.remove(requested)
        deferredEffectsByTarget[requested] = nil
        guard target == requested else { return }
        // A newer open owns the transition while the previously mounted target
        // remains visible. Its eventual close callback must not clear the new
        // owner's notice or subscription.
        guard pendingTarget == nil || pendingTarget == requested else { return }
        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
        target = nil
        if pendingTarget == requested { pendingTarget = nil }
        isAuthoritative = false
        snapshot = nil
        authoritativeTailSnapshot = nil
        hasLoadedTranscriptHistory = false
        advanceChatProjection(canonical: true)
        clearSecondaryProjection()
        await closeSubscription(requested.sessionID, expectedTarget: requested)
    }

    func loadEarlier(sessionID: String, presentationGeneration: Int) async {
        guard !loadingEarlierTranscript,
              let target,
              target.sessionID == sessionID,
              target.generation == presentationGeneration,
              owns(target),
              isAuthoritative,
              let subscriptionToken = installedSubscriptionToken(for: sessionID),
              let current = snapshot,
              let before = current.transcriptStart,
              before > 0 else { return }
        let expectedTotal: Int
        if let transcriptTotal = current.transcriptTotal {
            expectedTotal = transcriptTotal
        } else {
            let (derivedTotal, overflow) = before.addingReportingOverflow(current.transcript.count)
            guard !overflow else { return }
            expectedTotal = derivedTotal
        }
        let request = ChatTranscriptPageRequest(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration,
            runtimeGeneration: current.runtimeGeneration,
            before: before,
            expectedTotal: expectedTotal,
            expectedNextEntryID: current.transcript.first?.id
        )
        struct Params: Codable { let sessionId: String; let before: Int; let expectedNextEntryId: String? }
        struct Response: Decodable {
            let items: [TranscriptItem]
            let start: Int
            let end: Int?
            let total: Int
        }
        loadingEarlierTranscript = true
        discardLoadedHistoryAfterCurrentLoad = false
        defer {
            loadingEarlierTranscript = false
            discardLoadedHistoryAfterCurrentLoad = false
        }
        do {
            let response: Response = try await client.request(
                "session.transcript",
                Params(sessionId: sessionID, before: before, expectedNextEntryId: current.transcript.first?.id),
                timeout: .seconds(60)
            )
            guard !Task.isCancelled,
                  let currentTarget = self.mountedTarget,
                  currentTarget == target,
                  self.isAuthoritative,
                  self.installedSubscriptionToken(for: sessionID) == subscriptionToken,
                  var snapshot = self.snapshot,
                  request.canInstall(
                    sessionID: currentTarget.sessionID,
                    presentationGeneration: currentTarget.generation,
                    runtimeGeneration: snapshot.runtimeGeneration,
                    transcriptStart: snapshot.transcriptStart,
                    transcriptTotal: snapshot.transcriptTotal,
                    firstTranscriptID: snapshot.transcript.first?.id
                  ),
                  request.canInstallPage(
                    start: response.start,
                    end: response.end ?? before,
                    total: response.total,
                    itemCount: response.items.count,
                    visibleItemCount: snapshot.transcript.count
                  ),
                  !discardLoadedHistoryAfterCurrentLoad else { return }
            let existingIDs = Set(snapshot.transcript.map(\.id))
            let pageIDs = Set(response.items.map(\.id))
            guard pageIDs.count == response.items.count,
                  response.items.allSatisfy({ !existingIDs.contains($0.id) }) else { return }
            snapshot.transcript = response.items + snapshot.transcript
            snapshot.transcriptStart = response.start
            snapshot.transcriptTotal = response.total
            self.snapshot = snapshot
            hasLoadedTranscriptHistory = true
            advanceChatProjection(canonical: true)
            delegate?.sessionPresentationStoreCheckpointCache()
        } catch is CancellationError {
            return
        } catch {
            delegate?.sessionPresentationStoreSurface(error)
        }
    }

    func discardLoadedTranscriptHistory(
        sessionID: String,
        presentationGeneration: Int
    ) {
        guard mountedTarget == SessionPresentationIdentity(
            sessionID: sessionID,
            generation: presentationGeneration
        ) else { return }
        if loadingEarlierTranscript { discardLoadedHistoryAfterCurrentLoad = true }
        guard hasLoadedTranscriptHistory,
              let tail = authoritativeTailSnapshot,
              tail.sessionId == sessionID,
              tail.runtimeGeneration == snapshot?.runtimeGeneration else { return }
        snapshot = tail
        hasLoadedTranscriptHistory = false
        advanceChatProjection(canonical: true)
        delegate?.sessionPresentationStoreCheckpointCache()
    }

    func retireConnection() {
        connectionGeneration &+= 1
        deferredEffectsByTarget.removeAll()
        pendingRebaselines.removeAll()
        subscribedSessionID = nil
        subscriptionToken = nil
        subscriptionTarget = nil
        synchronization.reset()
        // Keep the last-good snapshot authoritative for the mounted chat, but
        // advance its presentation generation so the retained projection is
        // immediately observable and can accept the next reconnect owner.
        if mountedTarget != nil, snapshot != nil {
            advanceChatProjection(canonical: false)
        }
        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
    }

    func clearProfile() {
        nextPresentationGeneration &+= 1
        target = nil
        pendingTarget = nil
        snapshot = nil
        authoritativeTailSnapshot = nil
        hasLoadedTranscriptHistory = false
        advanceChatProjection(canonical: true)
        isAuthoritative = false
        revokedTargets.removeAll()
        retireConnection()
        clearSecondaryProjection()
    }

    func closeSubscriptionIfInstalled(sessionID: String) async {
        guard subscribedSessionID == sessionID else { return }
        await closeCurrentSubscription()
    }

    func remove(sessionID: String) {
        guard selectedSessionID == sessionID else { return }
        target = nil
        pendingTarget = nil
        snapshot = nil
        authoritativeTailSnapshot = nil
        hasLoadedTranscriptHistory = false
        advanceChatProjection(canonical: true)
        isAuthoritative = false
        revokedTargets = revokedTargets.filter { $0.sessionID != sessionID }
        deferredEffectsByTarget = deferredEffectsByTarget.filter { $0.key.sessionID != sessionID }
        retireConnection()
        clearSecondaryProjection()
    }

    func clearConfirmedQueue(sessionID: String) {
        guard ownsSession(sessionID), var snapshot else { return }
        snapshot.queued = .init(steering: [], followUp: [])
        snapshot.queuedItems = []
        self.snapshot = snapshot
        advanceChatProjection(canonical: false)
    }

    func admit(_ event: GatewayEvent) async {
        if event.topic == "session.rebaseline" {
            guard case .sessionRebaseline(let authoritative) = event.preparation,
                  event.sessionId == authoritative.sessionId,
                  ownsLiveSnapshotEvent(sessionID: authoritative.sessionId)
                    || ownsPendingSynchronization(sessionID: authoritative.sessionId) else { return }
            if !hasInstalledSubscription(for: authoritative.sessionId) {
                pendingRebaselines[authoritative.sessionId] = authoritative
                return
            }
            snapshot = authoritative
            authoritativeTailSnapshot = authoritative
            hasLoadedTranscriptHistory = false
            advanceChatProjection(canonical: true)
            isAuthoritative = mountedTarget?.sessionID == authoritative.sessionId
            delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
            delegate?.sessionPresentationStoreCheckpointCache()
            return
        }
        switch synchronization.admit(event) {
        case .deliver(let event):
            guard admitsSequencedEvent(event) else { return }
            if let sessionID = reduce(event) {
                _ = await synchronize(sessionID, operation: .sessionResync)
            }
        case .buffered:
            break
        case .overflow(let sessionID):
            _ = await synchronize(sessionID, operation: .sessionResync)
        }
    }

    func handleResyncRequired(sessionID: String?) async {
        if let sessionID = sessionID ?? subscribedSessionID {
            _ = await synchronize(sessionID, operation: .sessionResync)
        }
    }

    @discardableResult
    func reconnectMountedPresentation() async -> Bool {
        guard let target = mountedTarget else { return true }
        return await synchronize(
            target.sessionID,
            presentationGeneration: target.generation
        )
    }

    func loadContext(sessionID: String) async {
        guard let token = installedSubscriptionToken(for: sessionID) else { return }
        contextLoadGeneration &+= 1
        let generation = contextLoadGeneration
        struct Params: Codable { let sessionId: String }
        do {
            let loaded = try await client.requestValue("session.context", Params(sessionId: sessionID), timeout: .seconds(60))
            guard generation == contextLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            context = loaded
        } catch {
            guard !(error is CancellationError),
                  generation == contextLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            delegate?.sessionPresentationStoreSurface(error)
        }
    }

    func loadTree(sessionID: String) async {
        guard let token = installedSubscriptionToken(for: sessionID) else { return }
        treeLoadGeneration &+= 1
        let generation = treeLoadGeneration
        struct Params: Codable { let sessionId: String }
        do {
            let loaded: [SessionTreeNode] = try await client.request("session.tree", Params(sessionId: sessionID))
            guard generation == treeLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            let admitted = try SessionTreePolicy.admit(loaded)
            sessionTree = admitted
        } catch {
            guard !(error is CancellationError),
                  generation == treeLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            delegate?.sessionPresentationStoreSurface(error)
        }
    }

    func loadCommands(sessionID: String) async {
        guard let token = installedSubscriptionToken(for: sessionID) else { return }
        commandLoadGeneration &+= 1
        let generation = commandLoadGeneration
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let commands: [CommandInfo] }
        do {
            let response: Response = try await client.request("session.commands", Params(sessionId: sessionID))
            guard generation == commandLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            let admitted = try CommandCatalogPolicy.admit(response.commands)
            commands = admitted
        } catch {
            guard !(error is CancellationError),
                  generation == commandLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            delegate?.sessionPresentationStoreSurface(error)
        }
    }

    func loadResources(sessionID: String) async {
        guard let token = installedSubscriptionToken(for: sessionID) else { return }
        resourceLoadGeneration &+= 1
        let generation = resourceLoadGeneration
        struct Params: Codable { let sessionId: String }
        do {
            let loaded = try await client.requestValue("session.resources", Params(sessionId: sessionID), timeout: .seconds(60))
            guard generation == resourceLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            resources = loaded
        } catch {
            guard !(error is CancellationError),
                  generation == resourceLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token) else { return }
            delegate?.sessionPresentationStoreSurface(error)
        }
    }

    private func admitsSequencedEvent(_ event: GatewayEvent) -> Bool {
        guard let sessionID = event.sessionId,
              let target = mountedTarget,
              isAuthoritative,
              target.sessionID == sessionID,
              snapshot?.sessionId == sessionID,
              subscriptionTarget == target,
              subscribedSessionID == sessionID,
              subscriptionToken != nil else { return false }
        return true
    }

    private func ownsSession(_ sessionID: String) -> Bool {
        target?.sessionID == sessionID
            || pendingTarget?.sessionID == sessionID
            || snapshot?.sessionId == sessionID
    }

    private func ownsSubscription(sessionID: String, requestedToken: String) -> Bool {
        guard let target = mountedTarget else { return false }
        return isAuthoritative
            && target.sessionID == sessionID
            && subscribedSessionID == sessionID
            && subscriptionTarget == target
            && subscriptionToken == requestedToken
    }

    @discardableResult
    func prepareSecondaryProjectionForRuntimeInstallation(_ installed: SessionSnapshot) -> Bool {
        guard snapshot?.sessionId == installed.sessionId,
              snapshot?.runtimeGeneration != installed.runtimeGeneration else { return false }
        clearSecondaryProjection()
        structureRevision &+= 1
        contextRevision &+= 1
        resourceRevision &+= 1
        return true
    }

    private func clearSecondaryProjection() {
        contextLoadGeneration &+= 1
        treeLoadGeneration &+= 1
        commandLoadGeneration &+= 1
        resourceLoadGeneration &+= 1
        context = nil
        sessionTree = []
        commands = []
        resources = nil
    }

    private func closeCurrentSubscription() async -> Bool {
        guard let sessionID = subscribedSessionID else { return true }
        return await closeSubscription(sessionID, expectedTarget: nil)
    }

    @discardableResult
    private func closeSubscription(_ sessionID: String, expectedTarget: SessionPresentationIdentity?) async -> Bool {
        if let expectedTarget, subscriptionTarget != expectedTarget { return false }
        guard subscribedSessionID == sessionID, let token = subscriptionToken else { return true }
        let expectedConnectionGeneration = connectionGeneration
        let expectedSubscriptionTarget = subscriptionTarget
        struct Params: Codable { let sessionId, subscriptionToken: String }
        struct Response: Decodable { let closed: Bool }
        let response: Response? = try? await client.request(
            "session.close",
            Params(sessionId: sessionID, subscriptionToken: token)
        )
        guard connectionGeneration == expectedConnectionGeneration,
              subscribedSessionID == sessionID,
              subscriptionTarget == expectedSubscriptionTarget else { return false }
        // A decoded `closed:false` is authoritative evidence that the Gateway
        // no longer owns this token. Only an interrupted/undecodable request
        // retains local ownership for retry; never overwrite a newer owner.
        guard response != nil else { return false }
        subscriptionToken = nil
        subscribedSessionID = nil
        subscriptionTarget = nil
        return true
    }

    private func closeProvisionalSubscription(
        _ sessionID: String,
        token: String,
        expectedConnectionGeneration: Int
    ) async {
        // A retired connection's Gateway subscription is revoked with its
        // socket. Never send that stale token through a newer connection.
        guard connectionGeneration == expectedConnectionGeneration else { return }
        struct Params: Codable { let sessionId, subscriptionToken: String }
        struct Response: Decodable { let closed: Bool }
        let _: Response? = try? await client.request(
            "session.close",
            Params(sessionId: sessionID, subscriptionToken: token)
        )
    }

    static func ownsPresentation(mountedGeneration: Int?, requestedGeneration: Int) -> Bool {
        mountedGeneration == requestedGeneration
    }

    static func admitsPresentationIntake(
        mountedGeneration: Int?,
        requestedGeneration: Int,
        isRevoked: Bool
    ) -> Bool {
        !isRevoked && ownsPresentation(
            mountedGeneration: mountedGeneration,
            requestedGeneration: requestedGeneration
        )
    }

    static func ownsSubscription(
        sessionID: String,
        subscribedSessionID: String?,
        installedToken: String?,
        requestedToken: String
    ) -> Bool {
        subscribedSessionID == sessionID && installedToken == requestedToken
    }

    static func shouldClearSubscription(
        installedToken: String?,
        closingToken: String,
        gatewayClosed: Bool
    ) -> Bool {
        gatewayClosed && installedToken == closingToken
    }

    @discardableResult
    private func synchronize(
        _ sessionID: String,
        replacingVisibleTranscript: Bool = false,
        presentationGeneration: Int? = nil,
        operation: PerformanceOperation = .sessionSync
    ) async -> Bool {
        let intent: SessionSynchronizationCoordinator.Intent
        if replacingVisibleTranscript {
            guard let presentationGeneration else { return false }
            intent = .presentation(generation: presentationGeneration)
        } else {
            guard let mountedGeneration = presentationGeneration ?? target?.generation,
                  target?.sessionID == sessionID else { return false }
            intent = .reconnect(presentationGeneration: mountedGeneration)
        }

        while !Task.isCancelled {
            let lease = synchronization.acquire(sessionID: sessionID, intent: intent)
            switch lease.role {
            case .join:
                return await lease.sharedValue()
            case .retryAfterCurrent:
                _ = await lease.sharedValue()
            case .leader:
                synchronization.prepareLeaderAttempt(lease)
                pendingRebaselines[sessionID] = nil
                return await performSynchronization(sessionID: sessionID, lease: lease, operation: operation)
            }
        }
        return false
    }

    private enum AttemptOutcome {
        case success
        case retry
        case failed(showCatchUpNotice: Bool)
    }

    private enum ReducerEffect {
        case catalogRefresh
        case editor(action: SessionEditorAction, text: String, fullText: String, revision: Int, operationID: String?)
        case notice(String, type: String)
        case failure(GatewayFailure)
    }

    private func performSynchronization(
        sessionID: String,
        lease: SessionSynchronizationCoordinator.Lease,
        operation: PerformanceOperation
    ) async -> Bool {
        var nextOperation = operation
        let synchronizationConnectionGeneration = connectionGeneration
        for _ in 0..<3 {
            guard !Task.isCancelled,
                  synchronization.owns(lease),
                  ownsSynchronizationIntent(lease.intent, sessionID: sessionID) else {
                synchronization.complete(lease, outcome: false)
                return false
            }
            switch await performSynchronizationAttempt(sessionID: sessionID, lease: lease, operation: nextOperation) {
            case .success:
                synchronization.complete(lease, outcome: true)
                delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
                delegate?.sessionPresentationStoreCheckpointCache()
                return true
            case .retry:
                // The attempt may already have installed a subscription before
                // discovering a contiguous-replay race. Retire that exact
                // owner before opening the replacement attempt.
                if subscriptionToken != nil,
                   !(await closeSubscription(sessionID, expectedTarget: nil)) {
                    let ownsNotice = ownsSynchronizationAttempt(
                        lease,
                        sessionID: sessionID,
                        connectionGeneration: synchronizationConnectionGeneration
                    )
                    synchronization.complete(lease, outcome: false)
                    if ownsNotice { delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp) }
                    return false
                }
                synchronization.restartBuffer(for: lease)
                nextOperation = .sessionResync
            case .failed(let showCatchUpNotice):
                let ownsNotice = ownsSynchronizationAttempt(
                    lease,
                    sessionID: sessionID,
                    connectionGeneration: synchronizationConnectionGeneration
                ) && synchronizationTarget(for: lease.intent, sessionID: sessionID) != nil
                synchronization.complete(lease, outcome: false)
                guard ownsNotice else { return false }
                switch lease.intent {
                case .reconnect:
                    // A mounted chat has a retained authoritative snapshot. Do
                    // not replace its truthful native state with a global capsule
                    // while the connection owner is being recycled.
                    if snapshot != nil { advanceChatProjection(canonical: false) }
                    delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
                case .presentation:
                    if showCatchUpNotice {
                        delegate?.sessionPresentationStorePostNotice(Self.sessionCatchUpNotice, replacing: .sessionCatchUp)
                    } else {
                        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
                    }
                }
                return false
            }
        }
        if subscriptionToken != nil { await closeSubscription(sessionID, expectedTarget: nil) }
        let ownsNotice = ownsSynchronizationAttempt(
            lease,
            sessionID: sessionID,
            connectionGeneration: synchronizationConnectionGeneration
        ) && synchronizationTarget(for: lease.intent, sessionID: sessionID) != nil
        synchronization.complete(lease, outcome: false)
        if ownsNotice {
            switch lease.intent {
            case .reconnect:
                if snapshot != nil { advanceChatProjection(canonical: false) }
                delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp)
            case .presentation:
                delegate?.sessionPresentationStorePostNotice(Self.sessionCatchUpNotice, replacing: .sessionCatchUp)
            }
        }
        return false
    }

    private func performSynchronizationAttempt(
        sessionID: String,
        lease: SessionSynchronizationCoordinator.Lease,
        operation: PerformanceOperation
    ) async -> AttemptOutcome {
        let interval = performanceSignposts.begin(operation)
        var result = PerformanceResult.failure
        var metrics = PerformanceMetrics.none
        defer { performanceSignposts.end(interval, result: result, metrics: metrics) }
        let attemptConnectionGeneration = connectionGeneration
        var provisionalToken: String?
        do {
            try Task.checkCancellation()
            struct Params: Codable { let sessionId: String }
            let response: GatewaySessionOpenResponse = try await client.request(
                "session.open",
                Params(sessionId: sessionID),
                timeout: .seconds(60)
            )
            provisionalToken = response.subscriptionToken
            guard ownsSynchronizationAttempt(
                lease,
                sessionID: sessionID,
                connectionGeneration: attemptConnectionGeneration
            ) else {
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .failed(showCatchUpNotice: false)
            }

            try await acknowledgeSync(sessionID: sessionID, syncToken: response.syncToken)
            try Task.checkCancellation()
            guard ownsSynchronizationAttempt(
                lease,
                sessionID: sessionID,
                connectionGeneration: attemptConnectionGeneration
            ) else {
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .failed(showCatchUpNotice: false)
            }

            let authoritativeResponse = pendingRebaselines.removeValue(forKey: sessionID) ?? response.session
            let mode: SessionSnapshotInstallationMode
            switch lease.intent {
            case .presentation:
                mode = .freshPresentation
            case .reconnect:
                mode = synchronization.consumeFreshInstallRequirement(sessionID: sessionID)
                    ? .freshPresentation : .reconnect
            }
            let visibleCurrent = hasLoadedTranscriptHistory ? snapshot : nil
            var installed = Self.installingSnapshot(
                current: visibleCurrent,
                authoritative: authoritativeResponse,
                mode: mode
            )
            var installedTail = Self.installingAuthoritativeTail(
                current: authoritativeTailSnapshot,
                authoritative: authoritativeResponse,
                mode: mode
            )
            var replayEffects: [ReducerEffect] = []
            let cursor = SessionSynchronizationCoordinator.Cursor(
                runtimeGeneration: installed.runtimeGeneration,
                eventSequence: installed.eventSequence
            )
            guard ownsSynchronizationAttempt(
                      lease,
                      sessionID: sessionID,
                      connectionGeneration: attemptConnectionGeneration
                  ),
                  let replay = synchronization.drainBufferedEvents(for: lease, baseline: cursor),
                  SessionSynchronizationCoordinator.isContiguous(replay, after: cursor) else {
                if case .freshPresentation = mode { synchronization.requireFreshInstall(sessionID: sessionID) }
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .retry
            }

            // Reduce the complete quarantined suffix locally. Snapshot, token,
            // and route-keyed effects become observable only after acknowledgement
            // and contiguity establish the exact installed target.
            var replayChangedChatTimeline = false
            var replayRequiresResynchronization = false
            for event in replay {
                if reduce(
                    event,
                    snapshot: &installed,
                    effects: &replayEffects,
                    chatTimelineChanged: &replayChangedChatTimeline
                ) != nil { replayRequiresResynchronization = true }
                var ignoredEffects: [ReducerEffect] = []
                var ignoredChatTimelineChange = false
                if reduce(
                    event,
                    snapshot: &installedTail,
                    effects: &ignoredEffects,
                    chatTimelineChanged: &ignoredChatTimelineChange,
                    updatesSecondaryRevisions: false,
                    mergesVisibleTranscript: false
                ) != nil { replayRequiresResynchronization = true }
            }
            let replayTailSequence = replay.last?.sessionCursor?.eventSequence ?? cursor.eventSequence
            guard !replayRequiresResynchronization,
                  installed.eventSequence == replayTailSequence,
                  installedTail.eventSequence == replayTailSequence else {
                if case .freshPresentation = mode { synchronization.requireFreshInstall(sessionID: sessionID) }
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .retry
            }
            guard let installedTarget = synchronizationTarget(
                for: lease.intent,
                sessionID: sessionID
            ), ownsSynchronizationAttempt(
                lease,
                sessionID: sessionID,
                connectionGeneration: attemptConnectionGeneration
            ) else {
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .failed(showCatchUpNotice: false)
            }
            let replacedRuntime = prepareSecondaryProjectionForRuntimeInstallation(installed)
            subscribedSessionID = sessionID
            subscriptionToken = response.subscriptionToken
            subscriptionTarget = installedTarget
            snapshot = installed
            authoritativeTailSnapshot = installedTail
            if replacedRuntime {
                Task { [weak self] in await self?.loadCommands(sessionID: sessionID) }
            }
            if case .freshPresentation = mode { hasLoadedTranscriptHistory = false }
            advanceChatProjection(canonical: true)
            switch lease.intent {
            case .presentation:
                deferredEffectsByTarget[installedTarget, default: []].append(contentsOf: replayEffects)
            case .reconnect:
                publish(replayEffects, target: installedTarget)
            }
            provisionalToken = nil

            if synchronization.consumeRetryRequirement(for: lease) {
                result = .discarded
                return .retry
            }
            result = .success
            metrics = PerformanceMetrics(itemCount: replay.count)
            return .success
        } catch {
            if Task.isCancelled || error is CancellationError { result = .cancelled }
            if let provisionalToken {
                await closeProvisionalSubscription(
                    sessionID,
                    token: provisionalToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
            }
            guard ownsSynchronizationAttempt(
                lease,
                sessionID: sessionID,
                connectionGeneration: attemptConnectionGeneration
            ), synchronizationTarget(for: lease.intent, sessionID: sessionID) != nil else {
                return .failed(showCatchUpNotice: false)
            }
            let showCatchUpNotice: Bool
            if let failure = error as? GatewayFailure,
               failure.retryable || failure.code == "response_too_large" {
                showCatchUpNotice = true
            } else {
                showCatchUpNotice = false
                delegate?.sessionPresentationStoreSurface(error)
            }
            return .failed(showCatchUpNotice: showCatchUpNotice)
        }
    }

    private func synchronizationTarget(
        for intent: SessionSynchronizationCoordinator.Intent,
        sessionID: String
    ) -> SessionPresentationIdentity? {
        switch intent {
        case .presentation(let generation):
            let requested = SessionPresentationIdentity(sessionID: sessionID, generation: generation)
            return pendingTarget == requested ? requested : nil
        case .reconnect(let generation):
            let requested = SessionPresentationIdentity(sessionID: sessionID, generation: generation)
            return owns(requested) ? requested : nil
        }
    }

    private func ownsSynchronizationAttempt(
        _ lease: SessionSynchronizationCoordinator.Lease,
        sessionID: String,
        connectionGeneration: Int
    ) -> Bool {
        self.connectionGeneration == connectionGeneration
            && synchronization.owns(lease)
            && ownsSynchronizationIntent(lease.intent, sessionID: sessionID)
    }

    private func ownsSynchronizationIntent(
        _ intent: SessionSynchronizationCoordinator.Intent,
        sessionID: String
    ) -> Bool {
        switch intent {
        case .presentation(let generation):
            return pendingTarget == SessionPresentationIdentity(sessionID: sessionID, generation: generation)
        case .reconnect(let generation):
            return owns(SessionPresentationIdentity(sessionID: sessionID, generation: generation))
        }
    }

    private func acknowledgeSync(sessionID: String, syncToken: String) async throws {
        struct Params: Codable { let sessionId, syncToken: String }
        struct Response: Decodable { let synchronized: Bool }
        let response: Response = try await client.request(
            "session.sync",
            Params(sessionId: sessionID, syncToken: syncToken),
            timeout: .seconds(15)
        )
        guard response.synchronized else {
            throw GatewayFailure(code: "sync_failed", message: "Tron did not confirm session synchronization.", retryable: true, details: nil)
        }
    }

    private func reduce(_ event: GatewayEvent) -> String? {
        if event.topic == "session.snapshot",
           case .sessionSnapshot(let incoming) = event.preparation {
            return reduceSnapshotEvent(event, incoming: incoming)
        }
        guard var current = snapshot else {
            if event.topic == "session.snapshot", case .sessionSnapshot(let incoming) = event.preparation {
                return reduceSnapshotEvent(event, incoming: incoming)
            }
            if event.topic == "session.listChanged" { delegate?.sessionPresentationStoreDidRequestCatalogRefresh() }
            return nil
        }
        var effects: [ReducerEffect] = []
        var chatTimelineChanged = false
        let resync = reduce(
            event,
            snapshot: &current,
            effects: &effects,
            chatTimelineChanged: &chatTimelineChanged
        )
        if var tail = authoritativeTailSnapshot {
            var ignoredEffects: [ReducerEffect] = []
            var ignoredChatTimelineChange = false
            _ = reduce(
                event,
                snapshot: &tail,
                effects: &ignoredEffects,
                chatTimelineChanged: &ignoredChatTimelineChange,
                updatesSecondaryRevisions: false,
                mergesVisibleTranscript: false
            )
            authoritativeTailSnapshot = tail
        }
        snapshot = current
        if chatTimelineChanged { advanceChatProjection(canonical: false) }
        publish(effects, target: mountedTarget)
        return resync
    }

    private enum ExtensionPresentationAdmission { case applied, duplicate, resynchronize }

    private func applyExtensionPresentation(
        _ mutation: ExtensionPresentationMutation,
        snapshot: inout SessionSnapshot,
        effects: inout [ReducerEffect],
        chatTimelineChanged: inout Bool
    ) -> ExtensionPresentationAdmission {
        guard mutation.hostEpoch == snapshot.extensionPresentation.hostEpoch else { return .resynchronize }
        if mutation.revision == snapshot.extensionPresentation.revision { return .duplicate }
        guard mutation.revision == snapshot.extensionPresentation.revision + 1 else { return .resynchronize }
        var next = snapshot.extensionPresentation
        let previousSemantic = next.semanticState
        if let patch = mutation.semantic {
            if let statuses = patch.statuses { next.semanticState.statuses = statuses }
            if let working = patch.working { next.semanticState.working = working }
            if let value = patch.hiddenThinkingLabel {
                guard value == .null || value.stringValue != nil else { return .resynchronize }
                next.semanticState.hiddenThinkingLabel = value.stringValue
            }
            if let widgets = patch.widgets { next.semanticState.widgets = widgets }
            if let value = patch.title {
                guard value == .null || value.stringValue != nil else { return .resynchronize }
                next.semanticState.title = value.stringValue
            }
            if let expanded = patch.toolsExpanded { next.semanticState.toolsExpanded = expanded }
            let hasEditorDirective = patch.editorAction != nil || patch.editorDelta != nil || patch.editorOperationId != nil
            if patch.editorRevision != nil || patch.editorText != nil || hasEditorDirective {
                guard let revision = patch.editorRevision, let text = patch.editorText,
                      revision == next.semanticState.editorRevision + 1 else { return .resynchronize }
                let action = SessionEditorAction(rawValue: patch.editorAction ?? "set")
                guard let action else { return .resynchronize }
                let delta: String
                switch action {
                case .paste:
                    guard let supplied = patch.editorDelta,
                          next.semanticState.editorText + supplied == text,
                          patch.editorOperationId == nil else { return .resynchronize }
                    delta = supplied
                case .set:
                    guard (patch.editorDelta ?? text) == text,
                          patch.editorOperationId == nil else { return .resynchronize }
                    delta = text
                case .native:
                    guard (patch.editorDelta ?? text) == text,
                          patch.editorOperationId?.isEmpty == false else { return .resynchronize }
                    delta = text
                }
                next.semanticState.editorRevision = revision
                next.semanticState.editorText = text
                effects.append(.editor(
                    action: action, text: delta, fullText: text,
                    revision: revision, operationID: patch.editorOperationId
                ))
            }
        }
        if let interactions = mutation.interactionList { next.pendingInteractions = interactions }
        if let upserts = mutation.surfaceUpserts {
            for surface in upserts {
                if let index = next.surfaces.firstIndex(where: { $0.id == surface.id }) {
                    guard surface.revision == next.surfaces[index].revision + 1 else { return .resynchronize }
                    next.surfaces[index] = surface
                } else {
                    let omittedRevision = next.projection?.omittedSurfaces?.first(where: { $0.id == surface.id })?.revision
                    guard surface.revision == (omittedRevision.map { $0 + 1 } ?? 1) else { return .resynchronize }
                    next.surfaces.append(surface)
                }
                next.projection?.omittedSurfaces?.removeAll { $0.id == surface.id }
            }
        }
        if let removals = mutation.surfaceRemovals {
            let identities = Set(removals)
            next.surfaces.removeAll { identities.contains($0.id) }
            next.projection?.omittedSurfaces?.removeAll { identities.contains($0.id) }
        }
        if mutation.inputLeasePresent {
            guard let lease = mutation.inputLease else { return .resynchronize }
            if lease == .null { next.inputLease = nil }
            else if let decoded = try? lease.decode(ExtensionInputLease.self) { next.inputLease = decoded }
            else { return .resynchronize }
        }
        if let capabilities = mutation.capabilities { next.capabilities = capabilities }
        if let diagnostics = mutation.diagnostics { next.diagnostics = diagnostics }
        next.revision = mutation.revision
        if next.projection?.omitted == ["surfaces"], next.projection?.omittedSurfaces?.isEmpty == true {
            next.projection = nil
        }
        guard ExtensionPresentationPolicy.admit(next) else { return .resynchronize }
        if previousSemantic.statuses != next.semanticState.statuses
            || previousSemantic.working != next.semanticState.working
            || previousSemantic.hiddenThinkingLabel != next.semanticState.hiddenThinkingLabel { chatTimelineChanged = true }
        snapshot.extensionPresentation = next
        if let notification = mutation.notification { effects.append(.notice(notification.message, type: notification.type.rawValue)) }
        return .applied
    }

    private func reduce(
        _ event: GatewayEvent,
        snapshot: inout SessionSnapshot,
        effects: inout [ReducerEffect],
        chatTimelineChanged: inout Bool,
        updatesSecondaryRevisions: Bool = true,
        mergesVisibleTranscript: Bool = true
    ) -> String? {
        switch event.topic {
        case "session.summary":
            break
        case "session.listChanged":
            effects.append(.catalogRefresh)
        case "session.snapshot":
            guard case .sessionSnapshot(let incoming) = event.preparation else { break }
            switch SessionSnapshotEventAdmission.evaluate(
                eventSessionID: event.sessionId,
                hasLiveAuthority: true,
                current: snapshot,
                incoming: incoming
            ) {
            case .install:
                snapshot = mergesVisibleTranscript
                    ? Self.mergingVisibleTranscript(current: snapshot, authoritative: incoming)
                    : incoming
            case .ignore:
                break
            case .resynchronize(let sessionID):
                if !synchronization.markRetryRequired(sessionID: sessionID) { return sessionID }
            }
        case "session.progress":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .progress(let item)? = event.preparedSessionEvent?.data else { return resyncIfNeeded(event, snapshot: snapshot) }
            if snapshot.streaming != item {
                snapshot.streaming = item
                chatTimelineChanged = true
            }
            advance(&snapshot, envelope)
        case "session.toolProgress":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .toolProgress(let tool)? = event.preparedSessionEvent?.data else { return resyncIfNeeded(event, snapshot: snapshot) }
            if let index = snapshot.toolExecutions.firstIndex(where: { $0.toolCallId == tool.toolCallId }) {
                if ToolExecutionStatePolicy.shouldReplace(snapshot.toolExecutions[index], with: tool) {
                    snapshot.toolExecutions[index] = tool
                    chatTimelineChanged = true
                }
            } else {
                snapshot.toolExecutions.append(tool)
                chatTimelineChanged = true
            }
            if chatTimelineChanged { snapshot.toolExecutions.sort(by: ToolExecutionStatePolicy.orderedBefore) }
            advance(&snapshot, envelope)
        case "session.extensionPresentation":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .extensionPresentation(let mutation)? = event.preparedSessionEvent?.data else {
                return resyncIfNeeded(event, snapshot: snapshot)
            }
            switch applyExtensionPresentation(
                mutation, snapshot: &snapshot, effects: &effects,
                chatTimelineChanged: &chatTimelineChanged
            ) {
            case .applied, .duplicate:
                advance(&snapshot, envelope)
            case .resynchronize:
                return snapshot.sessionId
            }
        case "session.closed":
            guard let envelope = admitEnvelope(event, snapshot: snapshot) else { return resyncIfNeeded(event, snapshot: snapshot) }
            snapshot.phase = .interrupted
            snapshot.operation = nil
            snapshot.extensionCommand = nil
            effects.append(.notice("An extension closed this session runtime.", type: "info"))
            advance(&snapshot, envelope)
        case "session.operationFailed", "session.extensionError":
            guard let envelope = admitEnvelope(event, snapshot: snapshot) else { return resyncIfNeeded(event, snapshot: snapshot) }
            if let message = envelope.data.objectValue?["message"]?.stringValue {
                effects.append(.failure(GatewayFailure(
                    code: "session_operation_failed",
                    message: message,
                    retryable: false,
                    details: nil
                )))
            }
            advance(&snapshot, envelope)
        case "session.structureChanged":
            guard let envelope = admitEnvelope(event, snapshot: snapshot) else { return resyncIfNeeded(event, snapshot: snapshot) }
            if updatesSecondaryRevisions,
               envelope.data.objectValue?["branchChanged"]?.boolValue == true {
                synchronization.requireFreshInstall(sessionID: snapshot.sessionId)
            }
            advance(&snapshot, envelope)
            if updatesSecondaryRevisions {
                structureRevision &+= 1
                contextRevision &+= 1
            }
        case "session.contextChanged":
            guard let envelope = admitEnvelope(event, snapshot: snapshot) else { return resyncIfNeeded(event, snapshot: snapshot) }
            advance(&snapshot, envelope)
            if updatesSecondaryRevisions { contextRevision &+= 1 }
        case "session.resourcesChanged":
            guard let envelope = admitEnvelope(event, snapshot: snapshot) else { return resyncIfNeeded(event, snapshot: snapshot) }
            advance(&snapshot, envelope)
            if updatesSecondaryRevisions {
                resourceRevision &+= 1
                contextRevision &+= 1
            }
        default:
            if let envelope = admitEnvelope(event, snapshot: snapshot) { advance(&snapshot, envelope) }
            else { return resyncIfNeeded(event, snapshot: snapshot) }
        }
        return nil
    }

    private func publish(
        _ effects: [ReducerEffect],
        target: SessionPresentationIdentity?
    ) {
        for effect in effects {
            switch effect {
            case .catalogRefresh:
                delegate?.sessionPresentationStoreDidRequestCatalogRefresh()
            case .editor(let action, let text, let fullText, let revision, let operationID):
                guard let target else { continue }
                delegate?.sessionPresentationStoreDidPublishEditorRequest(
                    target: target,
                    action: action,
                    text: text,
                    fullText: fullText,
                    revision: revision,
                    operationID: operationID
                )
            case .notice(let message, let type):
                let presented = type == "info" ? message : "\(type == "warning" ? "Warning" : "Error"): \(message)"
                delegate?.sessionPresentationStorePostNotice(presented, replacing: nil)
            case .failure(let failure):
                delegate?.sessionPresentationStoreSurface(failure)
            }
        }
    }

    private func reduceSnapshotEvent(_ event: GatewayEvent, incoming: SessionSnapshot) -> String? {
        let hasAuthority = ownsLiveSnapshotEvent(sessionID: event.sessionId ?? "")
        switch SessionSnapshotEventAdmission.evaluate(
            eventSessionID: event.sessionId,
            hasLiveAuthority: hasAuthority,
            current: snapshot,
            incoming: incoming
        ) {
        case .install:
            let installed = hasLoadedTranscriptHistory
                ? snapshot.map { Self.mergingVisibleTranscript(current: $0, authoritative: incoming) } ?? incoming
                : incoming
            snapshot = installed
            authoritativeTailSnapshot = incoming
            if installed.transcriptStart == incoming.transcriptStart,
               installed.transcript.map(\.id) == incoming.transcript.map(\.id) {
                hasLoadedTranscriptHistory = false
            }
            advanceChatProjection(canonical: true)
            if installed.transcriptStart == incoming.transcriptStart,
               installed.transcript.count == incoming.transcript.count {
                delegate?.sessionPresentationStoreCheckpointCache()
            }
        case .ignore:
            break
        case .resynchronize(let sessionID):
            if !synchronization.markRetryRequired(sessionID: sessionID) { return sessionID }
        }
        return nil
    }

    private func ownsPendingSynchronization(sessionID: String) -> Bool {
        synchronization.intent(sessionID: sessionID).map {
            ownsSynchronizationIntent($0, sessionID: sessionID)
        } ?? false
    }

    private func ownsLiveSnapshotEvent(sessionID: String) -> Bool {
        guard hasInstalledSubscription(for: sessionID) else { return false }
        let mounted = mountedTarget?.sessionID == sessionID && isAuthoritative
        let synchronizing = synchronization.intent(sessionID: sessionID).map {
            ownsSynchronizationIntent($0, sessionID: sessionID)
        } ?? false
        return mounted || synchronizing
    }

    private func admitEnvelope(_ event: GatewayEvent, snapshot: SessionSnapshot) -> SessionEventEnvelope? {
        guard event.sessionId == snapshot.sessionId,
              let envelope = event.preparedSessionEvent?.envelope,
              envelope.runtimeGeneration == snapshot.runtimeGeneration,
              envelope.eventSequence == snapshot.eventSequence + 1 else { return nil }
        return envelope
    }

    private func resyncIfNeeded(_ event: GatewayEvent, snapshot: SessionSnapshot) -> String? {
        guard event.sessionId == snapshot.sessionId else { return nil }
        guard let envelope = event.preparedSessionEvent?.envelope else {
            // A recognized owned session topic that could not produce an
            // envelope is not safely ignorable: fail closed to authority.
            return hasInstalledSubscription(for: snapshot.sessionId) ? snapshot.sessionId : nil
        }
        if envelope.runtimeGeneration != snapshot.runtimeGeneration
            || envelope.eventSequence >= snapshot.eventSequence + 1 {
            if !synchronization.markRetryRequired(sessionID: snapshot.sessionId) { return snapshot.sessionId }
        }
        return nil
    }

    private func advance(_ snapshot: inout SessionSnapshot, _ envelope: SessionEventEnvelope) {
        snapshot.eventSequence = envelope.eventSequence
        snapshot.revision = max(snapshot.revision, envelope.revision)
    }

    private func advanceChatProjection(canonical: Bool) {
        if canonical { chatCanonicalGeneration &+= 1 }
        chatTimelineGeneration &+= 1
    }

    static func installingSnapshot(
        current: SessionSnapshot?,
        authoritative: SessionSnapshot,
        mode: SessionSnapshotInstallationMode
    ) -> SessionSnapshot {
        switch mode {
        case .freshPresentation:
            return authoritative
        case .reconnect:
            guard let current else { return authoritative }
            if current.runtimeGeneration == authoritative.runtimeGeneration,
               authoritative.eventSequence < current.eventSequence { return current }
            return mergingVisibleTranscript(current: current, authoritative: authoritative)
        }
    }

    static func installingAuthoritativeTail(
        current: SessionSnapshot?,
        authoritative: SessionSnapshot,
        mode: SessionSnapshotInstallationMode
    ) -> SessionSnapshot {
        guard case .reconnect = mode,
              let current,
              current.sessionId == authoritative.sessionId,
              current.runtimeGeneration == authoritative.runtimeGeneration,
              authoritative.eventSequence < current.eventSequence else {
            return authoritative
        }
        return current
    }

    static func mergingVisibleTranscript(
        current: SessionSnapshot,
        authoritative: SessionSnapshot
    ) -> SessionSnapshot {
        guard current.sessionId == authoritative.sessionId,
              current.runtimeGeneration == authoritative.runtimeGeneration,
              !current.transcript.isEmpty,
              (current.transcriptStart ?? 0) >= 0,
              (authoritative.transcriptStart ?? 0) >= 0 else { return authoritative }
        guard !authoritative.transcript.isEmpty else {
            guard authoritative.phase.isActive else { return authoritative }
            var merged = authoritative
            merged.transcript = current.transcript
            merged.transcriptStart = current.transcriptStart
            merged.transcriptTotal = max(
                authoritative.transcriptTotal ?? 0,
                current.transcriptTotal ?? current.transcript.count
            )
            return merged
        }
        let currentIndexByID = Dictionary(
            uniqueKeysWithValues: current.transcript.enumerated().map { ($0.element.id, $0.offset) }
        )
        guard let overlap = authoritative.transcript.enumerated().compactMap({ index, item -> (Int, Int)? in
            currentIndexByID[item.id].map { ($0, index) }
        }).first else {
            let currentStart = current.transcriptStart ?? 0
            let authoritativeStart = authoritative.transcriptStart ?? 0
            let (currentEnd, currentEndOverflow) = currentStart.addingReportingOverflow(
                current.transcript.count
            )
            guard !currentEndOverflow,
                  authoritative.phase.isActive,
                  authoritativeStart == currentEnd else { return authoritative }
            let (authoritativeEnd, authoritativeEndOverflow) = authoritativeStart
                .addingReportingOverflow(authoritative.transcript.count)
            guard !authoritativeEndOverflow else { return authoritative }
            var merged = authoritative
            merged.transcript = current.transcript + authoritative.transcript
            merged.transcriptStart = currentStart
            merged.transcriptTotal = max(
                authoritative.transcriptTotal ?? authoritativeEnd,
                current.transcriptTotal ?? currentEnd
            )
            return merged
        }
        let currentOverlap = current.transcript[overlap.0...].map(\.id)
        let authoritativeOverlap = authoritative.transcript[overlap.1...].map(\.id)
        let sharedCount = min(currentOverlap.count, authoritativeOverlap.count)
        guard Array(currentOverlap.prefix(sharedCount)) == Array(authoritativeOverlap.prefix(sharedCount)) else {
            return authoritative
        }
        let authoritativeIDs = Set(authoritative.transcript.map(\.id))
        let loadedPrefix = current.transcript[..<overlap.0].filter { !authoritativeIDs.contains($0.id) }
        var merged = authoritative
        merged.transcript = Array(loadedPrefix) + authoritative.transcript
        merged.transcriptStart = max(0, current.transcriptStart ?? 0)
        let (mergedEnd, mergedEndOverflow) = merged.transcriptStart!
            .addingReportingOverflow(merged.transcript.count)
        let knownTotal = max(
            authoritative.transcriptTotal ?? authoritative.transcript.count,
            current.transcriptTotal ?? 0
        )
        merged.transcriptTotal = mergedEndOverflow ? knownTotal : max(knownTotal, mergedEnd)
        return merged
    }

    static let sessionCatchUpNotice = "Live session view is catching up; the run continues on your Mac."

    #if HOSTED_TEST
    func installHostedSecondaryProjection(
        context: JSONValue?,
        tree: [SessionTreeNode],
        commands: [CommandInfo],
        resources: JSONValue?
    ) {
        self.context = context
        sessionTree = tree
        self.commands = commands
        self.resources = resources
    }

    func installCompatibilitySelection(_ sessionID: String?) {
        guard let sessionID else {
            target = nil
            pendingTarget = nil
            isAuthoritative = false
            clearSecondaryProjection()
            return
        }
        nextPresentationGeneration &+= 1
        target = SessionPresentationIdentity(sessionID: sessionID, generation: nextPresentationGeneration)
        pendingTarget = nil
        isAuthoritative = snapshot?.sessionId == sessionID
        clearSecondaryProjection()
    }

    func installHostedSnapshotWithoutPresentation(_ snapshot: SessionSnapshot) {
        target = nil
        pendingTarget = nil
        self.snapshot = snapshot
        authoritativeTailSnapshot = snapshot
        hasLoadedTranscriptHistory = false
        advanceChatProjection(canonical: true)
        isAuthoritative = false
    }

    func installHostedSubscription(
        snapshot: SessionSnapshot,
        token: String
    ) {
        installHostedAuthoritativeSnapshot(snapshot)
        subscribedSessionID = snapshot.sessionId
        subscriptionToken = token
        subscriptionTarget = target
    }

    func replaceHostedSubscriptionToken(_ token: String) {
        guard subscribedSessionID != nil else { return }
        subscriptionToken = token
    }

    func installHostedLoadedHistory(
        visible: SessionSnapshot,
        authoritativeTail: SessionSnapshot
    ) {
        guard target?.sessionID == visible.sessionId,
              visible.sessionId == authoritativeTail.sessionId else { return }
        snapshot = visible
        authoritativeTailSnapshot = authoritativeTail
        hasLoadedTranscriptHistory = true
        advanceChatProjection(canonical: true)
    }

    func replaceHostedSnapshot(_ snapshot: SessionSnapshot) {
        guard target?.sessionID == snapshot.sessionId else { return }
        let canonicalChanged = self.snapshot.map {
            $0.runtimeGeneration != snapshot.runtimeGeneration
                || $0.transcriptStart != snapshot.transcriptStart
                || $0.transcriptTotal != snapshot.transcriptTotal
                || $0.transcript != snapshot.transcript
        } ?? true
        let installsLoadedPrefix = authoritativeTailSnapshot.map { tail in
            tail.runtimeGeneration == snapshot.runtimeGeneration
                && (
                    (snapshot.transcriptStart ?? 0) < (tail.transcriptStart ?? 0)
                        || snapshot.transcript.count > tail.transcript.count
                )
                && !Set(tail.transcript.map(\.id)).isDisjoint(with: snapshot.transcript.map(\.id))
        } ?? false
        self.snapshot = snapshot
        if installsLoadedPrefix {
            hasLoadedTranscriptHistory = true
        } else {
            authoritativeTailSnapshot = snapshot
        }
        advanceChatProjection(canonical: canonicalChanged)
    }

    func invalidateHostedPendingPresentation() {
        nextPresentationGeneration &+= 1
        pendingTarget = nil
    }

    func installHostedAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        nextPresentationGeneration &+= 1
        let target = SessionPresentationIdentity(sessionID: snapshot.sessionId, generation: nextPresentationGeneration)
        self.target = target
        pendingTarget = nil
        self.snapshot = snapshot
        authoritativeTailSnapshot = snapshot
        hasLoadedTranscriptHistory = false
        advanceChatProjection(canonical: true)
        isAuthoritative = true
        revokedTargets.remove(target)
    }
    #endif
}
