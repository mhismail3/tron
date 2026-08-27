import Foundation
import Observation

struct SessionPresentationIdentity: Hashable, Sendable {
    let sessionID: String
    let generation: Int
}

enum SessionSnapshotInstallationMode { case freshPresentation, reconnect }
enum SessionEditorAction: String, Hashable, Sendable { case set, paste, native }

enum SessionTranscriptLoadState: Equatable, Sendable {
    case idle
    case loading
    case failed(String)
}

enum SessionTranscriptLoadResult: Equatable, Sendable {
    case installed
    case unavailable
    case stale
    case failed
}

struct MountedTranscriptCoverage: Equatable, Sendable {
    let sessionID: String
    let runtimeGeneration: String
    let leafEntryID: String?
    let total: Int
    let start: Int
    let end: Int
    let structureRevision: Int
}

/// The mounted transcript owns only the retained prefix. The Gateway tail
/// remains in SessionSnapshot and is never copied into this window.
struct MountedTranscriptWindow: Equatable, Sendable {
    let coverage: MountedTranscriptCoverage
    let prefixItems: [TranscriptItem]
}

enum GatewayTokenAdmissionPolicy {
    static let maximumUTF8Bytes = 200

    static func admit(_ token: String) -> Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && token.utf8.count <= maximumUTF8Bytes
            && !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct GatewaySessionOpenResponse: Decodable {
    let session: SessionSnapshot
    let syncToken: String
    let subscriptionToken: String
    let completionRevision: Int

    private enum CodingKeys: String, CodingKey { case session, syncToken, subscriptionToken, completionRevision }
    private enum SessionDiagnosticKeys: String, CodingKey {
        case extensionPresentation, extensionActivities, processOverview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionSnapshot.self, forKey: .session)
        func invalidSessionProjection(_ key: SessionDiagnosticKeys, _ description: String) -> DecodingError {
            .dataCorrupted(.init(
                codingPath: container.codingPath + [CodingKeys.session, key],
                debugDescription: description
            ))
        }
        guard ExtensionPresentationPolicy.admit(session.extensionPresentation) else {
            throw invalidSessionProjection(.extensionPresentation, "Invalid extension presentation snapshot")
        }
        guard ExtensionActivityAdmissionPolicy.admitsSnapshotFacts(session) else {
            throw invalidSessionProjection(.extensionActivities, "Invalid extension activity snapshot")
        }
        guard SessionProcessAdmissionPolicy.admitsSnapshotFacts(session) else {
            throw invalidSessionProjection(.processOverview, "Invalid process activity snapshot")
        }
        let decodedSyncToken = try container.decode(String.self, forKey: .syncToken)
        let decodedSubscriptionToken = try container.decode(String.self, forKey: .subscriptionToken)
        let decodedCompletionRevision = try container.decodeIfPresent(Int.self, forKey: .completionRevision) ?? 0
        guard GatewayTokenAdmissionPolicy.admit(decodedSyncToken) else {
            throw DecodingError.dataCorruptedError(forKey: .syncToken, in: container, debugDescription: "Invalid sync token")
        }
        guard GatewayTokenAdmissionPolicy.admit(decodedSubscriptionToken) else {
            throw DecodingError.dataCorruptedError(forKey: .subscriptionToken, in: container, debugDescription: "Invalid subscription token")
        }
        syncToken = decodedSyncToken
        guard decodedCompletionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .completionRevision, in: container, debugDescription: "Invalid completion revision")
        }
        subscriptionToken = decodedSubscriptionToken
        completionRevision = decodedCompletionRevision
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
    func sessionPresentationStoreDidPublishSnapshot(
        _ snapshot: SessionSnapshot,
        target: SessionPresentationIdentity
    )
    func sessionPresentationStoreDidFailOperation(
        operationID: String,
        target: SessionPresentationIdentity
    )
    func sessionPresentationStorePostNotice(
        _ message: String,
        replacing key: InAppNoticeKey?,
        role: InAppNoticeCenter.Role,
        scope: InAppNoticeScope?
    )
    func sessionPresentationStoreRemoveNotice(_ key: InAppNoticeKey, scope: InAppNoticeScope?)
    func sessionPresentationStoreRetireNoticeScope(_ scope: InAppNoticeScope)
    func sessionPresentationStoreSurface(_ error: Error)
    func sessionPresentationStoreCheckpointCache()
}

extension SessionPresentationStoreDelegate {
    func sessionPresentationStoreDidFailOperation(
        operationID: String,
        target: SessionPresentationIdentity
    ) {}
}

@MainActor
@Observable
final class SessionPresentationStore {
    private let client: GatewayClient
    private let performanceSignposts: any PerformanceSignposting
    weak var delegate: (any SessionPresentationStoreDelegate)?

    private func noticeScope(for target: SessionPresentationIdentity?) -> InAppNoticeScope? {
        target.map { .session(id: $0.sessionID, generation: $0.generation) }
    }

    // During an opening transition, notices belong to the pending presentation
    // rather than the still-mounted target. This prevents new errors from
    // being retired by a stale close of the previous presentation.
    private var noticeScope: InAppNoticeScope? {
        noticeScope(for: pendingTarget ?? target)
    }

    private func retireNoticeScopes(_ targets: [SessionPresentationIdentity?]) {
        var scopes = Set<InAppNoticeScope>()
        for target in targets {
            if let scope = noticeScope(for: target) { scopes.insert(scope) }
        }
        for scope in scopes { delegate?.sessionPresentationStoreRetireNoticeScope(scope) }
    }

    private func mount(_ requested: SessionPresentationIdentity) {
        let previousTarget = target
        let previousPendingTarget = pendingTarget
        target = requested
        pendingTarget = nil
        if revokedTarget == requested { revokedTarget = nil }
        retireNoticeScopes([
            previousTarget,
            previousPendingTarget == requested ? nil : previousPendingTarget
        ])
    }

    private(set) var target: SessionPresentationIdentity?
    private var pendingTarget: SessionPresentationIdentity?
    private(set) var snapshot: SessionSnapshot?
    private(set) var chatCanonicalGeneration = 0
    private(set) var chatTimelineGeneration = 0
    private(set) var isAuthoritative = false
    @ObservationIgnored private var mountedTranscriptWindow: MountedTranscriptWindow?
    private(set) var loadingEarlierTranscript = false
    private(set) var transcriptLoadState: SessionTranscriptLoadState = .idle
    @ObservationIgnored private var transcriptLoadTarget: SessionPresentationIdentity?
    // At most one target can be mounted or in replacement intake. Keeping the
    // revoked marker exact avoids retaining every historical presentation.
    private var revokedTarget: SessionPresentationIdentity?
    private var nextPresentationGeneration = 0
    // Every Gateway connection owns a distinct token namespace. Responses and
    // close completions from an older connection must not mutate new ownership.
    private var connectionGeneration = 0
    private var subscribedSessionID: String?
    private var subscriptionToken: String?
    private var subscriptionTarget: SessionPresentationIdentity?
    private struct PendingAttentionRead {
        let sessionID: String
        let throughCompletionRevision: Int
        let target: SessionPresentationIdentity
        let subscriptionToken: String
        let connectionGeneration: Int
    }
    private var pendingAttentionRead: PendingAttentionRead?
    @ObservationIgnored private var attentionReadTask: Task<Void, Never>?
    private var pendingSubscriptionTokens: [String: String] = [:]
    private var pendingRebaselines: [String: PreparedSessionRebaseline] = [:]
    private let synchronization = SessionSynchronizationCoordinator()
    private var deferredEffectsByTarget: [SessionPresentationIdentity: [ReducerEffect]] = [:]
    private var terminalSynchronizationFailures: [SessionPresentationIdentity: GatewayFailure] = [:]

    private(set) var context: JSONValue?
    private(set) var sessionTree: [SessionTreeNode] = []
    private(set) var commands: [CommandInfo] = []
    private(set) var commandCatalogTarget: SessionPresentationIdentity?
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

    var mountedTranscriptCoverage: MountedTranscriptCoverage? {
        guard let snapshot else { return nil }
        return mountedWindow(for: snapshot)?.coverage
    }

    var visibleTranscript: [TranscriptItem] {
        guard let snapshot else { return [] }
        return visibleTranscriptItems(for: snapshot)
    }

    var visibleTranscriptStart: Int? { mountedTranscriptCoverage?.start ?? snapshot?.transcriptStart }
    var visibleTranscriptEnd: Int? { mountedTranscriptCoverage?.end ?? authorityTranscriptEnd(snapshot) }
    var visibleTranscriptTotal: Int? { mountedTranscriptCoverage?.total ?? snapshot?.transcriptTotal }
    var hasEarlierTranscript: Bool { (visibleTranscriptStart ?? 0) > 0 }
    var hasLoadedTranscriptPrefix: Bool { mountedTranscriptWindow?.prefixItems.isEmpty == false }

    func transcriptSnapshot(for sessionID: String) -> SessionSnapshot? {
        guard ownsSession(sessionID), let snapshot, snapshot.sessionId == sessionID else { return nil }
        var projection = snapshot
        projection.transcript = visibleTranscriptItems(for: snapshot)
        projection.transcriptStart = visibleTranscriptStart
        projection.transcriptTotal = visibleTranscriptTotal
        return projection
    }

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
        target == requested && revokedTarget != requested
    }

    func revokeIntake(_ requested: SessionPresentationIdentity) {
        guard target == requested else { return }
        revokedTarget = requested
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
        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
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
        terminalSynchronizationFailures[requested] = nil
        transcriptLoadTarget = nil
        loadingEarlierTranscript = false
        transcriptLoadState = .idle
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
                // Failed intake owns no presentation UI. Retire its exact
                // notice scope before dropping the pending target so a
                // catch-up/error capsule cannot leak into a later route.
                retireNoticeScopes([requested])
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
        if !synchronized,
           let failure = terminalSynchronizationFailures.removeValue(forKey: requested) {
            throw failure
        }
        guard synchronized,
              owns(requested),
              subscribedSessionID == sessionID,
              subscriptionTarget == requested else {
            throw GatewayFailure(code: "sync_failed", message: "Tron could not synchronize this session.", retryable: true, details: nil)
        }
        didOpen = true
        result = .success
        return requested.generation
    }

    func close(_ requested: SessionPresentationIdentity) async {
        // A newer open owns the transition while the previously mounted target
        // remains visible. Its eventual close callback must not clear the new
        // owner's revocation, notice, or subscription.
        guard target == requested,
              pendingTarget == nil || pendingTarget == requested else { return }
        // Only the exact mounted/pending owner may release its revocation. A
        // stale close during replacement must leave the newer pending scope
        // untouched.
        let oldTarget = target
        let oldPendingTarget = pendingTarget
        if revokedTarget == requested { revokedTarget = nil }
        deferredEffectsByTarget[requested] = nil
        retireNoticeScopes([oldTarget, oldPendingTarget])
        target = nil
        if pendingTarget == requested { pendingTarget = nil }
        isAuthoritative = false
        transcriptLoadTarget = nil
        loadingEarlierTranscript = false
        transcriptLoadState = .idle
        snapshot = nil
        mountedTranscriptWindow = nil
        advanceChatProjection(canonical: true)
        clearSecondaryProjection()
        await closeSubscription(requested.sessionID, expectedTarget: requested)
    }

    private func authorityTranscriptEnd(_ snapshot: SessionSnapshot?) -> Int? {
        guard let snapshot, let start = snapshot.transcriptStart,
              start >= 0 else { return nil }
        let (end, overflow) = start.addingReportingOverflow(snapshot.transcript.count)
        return overflow ? nil : end
    }

    private func mountedWindow(for authority: SessionSnapshot) -> MountedTranscriptWindow? {
        guard let window = mountedTranscriptWindow,
              window.coverage.sessionID == authority.sessionId,
              window.coverage.runtimeGeneration == authority.runtimeGeneration,
              window.coverage.leafEntryID == authority.leafEntryId,
              window.coverage.structureRevision == structureRevision,
              let authorityTotal = authority.transcriptTotal,
              window.coverage.total == authorityTotal,
              let tailStart = authority.transcriptStart,
              tailStart >= window.coverage.start,
              window.prefixItems.count == tailStart - window.coverage.start,
              window.coverage.end == authorityTranscriptEnd(authority),
              Set(window.prefixItems.map(\.id)).count == window.prefixItems.count,
              Set(authority.transcript.map(\.id)).count == authority.transcript.count,
              Set(window.prefixItems.map(\.id)).isDisjoint(with: authority.transcript.map(\.id)) else {
            return nil
        }
        return window
    }

    private func visibleTranscriptItems(for authority: SessionSnapshot) -> [TranscriptItem] {
        guard let window = mountedWindow(for: authority) else { return authority.transcript }
        return window.prefixItems + authority.transcript
    }

    private func coverage(for authority: SessionSnapshot, prefix: [TranscriptItem], start: Int? = nil) -> MountedTranscriptCoverage? {
        guard let tailStart = authority.transcriptStart,
              let tailEnd = authorityTranscriptEnd(authority),
              let total = authority.transcriptTotal else { return nil }
        let resolvedStart = start ?? (prefix.isEmpty ? tailStart : tailStart - prefix.count)
        guard resolvedStart >= 0, resolvedStart <= tailStart,
              prefix.count == tailStart - resolvedStart,
              total >= tailEnd,
              Set(prefix.map(\.id)).count == prefix.count,
              Set(prefix.map(\.id)).isDisjoint(with: authority.transcript.map(\.id)) else { return nil }
        return MountedTranscriptCoverage(
            sessionID: authority.sessionId,
            runtimeGeneration: authority.runtimeGeneration,
            leafEntryID: authority.leafEntryId,
            total: total,
            start: resolvedStart,
            end: tailEnd,
            structureRevision: structureRevision
        )
    }

    private func reconcilePrefix(
        _ window: MountedTranscriptWindow?,
        from oldAuthority: SessionSnapshot?,
        into authority: SessionSnapshot
    ) -> MountedTranscriptWindow? {
        guard let window, let oldAuthority,
              let oldTailStart = oldAuthority.transcriptStart,
              let oldTailEnd = authorityTranscriptEnd(oldAuthority),
              let newTailStart = authority.transcriptStart,
              let newTailEnd = authorityTranscriptEnd(authority),
              let oldTotal = oldAuthority.transcriptTotal,
              let newTotal = authority.transcriptTotal,
              oldTailStart >= 0,
              newTailStart >= 0,
              oldTailEnd >= oldTailStart,
              newTailEnd >= newTailStart,
              window.coverage.sessionID == oldAuthority.sessionId,
              oldAuthority.sessionId == authority.sessionId,
              window.coverage.runtimeGeneration == oldAuthority.runtimeGeneration,
              oldAuthority.runtimeGeneration == authority.runtimeGeneration,
              window.coverage.leafEntryID == oldAuthority.leafEntryId,
              window.coverage.structureRevision == structureRevision,
              window.coverage.total == oldTotal,
              window.coverage.start >= 0,
              window.coverage.end == oldTailEnd,
              window.coverage.start <= oldTailStart,
              window.prefixItems.count == oldTailStart - window.coverage.start,
              oldTotal >= oldTailEnd,
              newTotal >= oldTotal,
              newTotal >= newTailEnd else { return nil }

        // Validate the old mounted window before consulting the replacement.
        // The prefix and authority tail are one exact visible sequence at
        // their canonical ordinals; never infer continuity from a leaf alone.
        let oldVisible = window.prefixItems + oldAuthority.transcript
        let oldVisibleStart = window.coverage.start
        let oldVisibleEnd = window.coverage.end
        guard oldVisible.count == oldVisibleEnd - oldVisibleStart,
              Set(oldVisible.map(\.id)).count == oldVisible.count else { return nil }

        // A replacement tail must share at least one canonical ordinal with
        // the old visible sequence, or begin exactly at its end. The latter
        // is an adjacent append: there is no overlap to validate, but also no
        // unfillable gap. The only other exception is two empty windows.
        let bothEmpty = oldVisible.isEmpty && authority.transcript.isEmpty
        let adjacentAppend = newTailStart == oldVisibleEnd
        guard bothEmpty || adjacentAppend || (
            newTailStart < oldVisibleEnd
                && newTailEnd > oldVisibleStart
        ), newTailStart <= oldVisibleEnd else { return nil }

        let overlapStart = max(oldVisibleStart, newTailStart)
        let overlapEnd = min(oldVisibleEnd, newTailEnd)
        if overlapStart < overlapEnd {
            for index in overlapStart..<overlapEnd {
                let oldOffset = index - oldVisibleStart
                let newOffset = index - newTailStart
                guard oldVisible[oldOffset].id == authority.transcript[newOffset].id else {
                    return nil
                }
            }
        }

        // Retain exactly the old visible rows before the replacement tail.
        // When the replacement reaches or precedes the visible start there is
        // no mounted prefix to retain; the authority tail remains canonical.
        let prefixCount = max(0, newTailStart - oldVisibleStart)
        guard prefixCount <= oldVisible.count else { return nil }
        guard prefixCount > 0 else { return nil }
        let retainedPrefix = Array(oldVisible.prefix(prefixCount))
        guard let coverage = coverage(
            for: authority,
            prefix: retainedPrefix,
            start: oldVisibleStart
        ), coverage.end == newTailEnd else { return nil }
        return MountedTranscriptWindow(coverage: coverage, prefixItems: retainedPrefix)
    }

    func loadEarlier(sessionID: String, presentationGeneration: Int) async -> SessionTranscriptLoadResult {
        guard !loadingEarlierTranscript else { return .unavailable }
        guard let loadTarget = mountedTarget,
              loadTarget.sessionID == sessionID,
              loadTarget.generation == presentationGeneration,
              owns(loadTarget),
              isAuthoritative else {
            transcriptLoadState = .failed("Earlier messages are not available on this presentation.")
            return .unavailable
        }
        transcriptLoadTarget = loadTarget
        loadingEarlierTranscript = true
        transcriptLoadState = .loading
        defer {
            if transcriptLoadTarget == loadTarget {
                transcriptLoadTarget = nil
                loadingEarlierTranscript = false
            }
        }

        struct Params: Codable {
            let sessionId: String
            let before: Int
            let expectedNextEntryId: String?
            let expectedRuntimeGeneration: String
            let expectedLeafEntryId: String?
        }
        struct Response: Decodable {
            let items: [TranscriptItem]
            let start: Int
            let end: Int?
            let total: Int
            let nextEntryId: String?
            let runtimeGeneration: String?
            let leafEntryId: String?
            let leafEntryIdPresent: Bool

            private enum CodingKeys: String, CodingKey {
                case items, start, end, total, nextEntryId, runtimeGeneration, leafEntryId
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                items = try values.decode([TranscriptItem].self, forKey: .items)
                start = try values.decode(Int.self, forKey: .start)
                end = try values.decodeIfPresent(Int.self, forKey: .end)
                total = try values.decode(Int.self, forKey: .total)
                nextEntryId = try values.decodeIfPresent(String.self, forKey: .nextEntryId)
                runtimeGeneration = try values.decodeIfPresent(String.self, forKey: .runtimeGeneration)
                leafEntryId = try values.decodeIfPresent(String.self, forKey: .leafEntryId)
                leafEntryIdPresent = values.contains(.leafEntryId)
            }
        }
        // A cursor can become stale while the Gateway request is suspended.
        // Retry a bounded number of times; never recurse through an unbounded
        // stream of moving cursors or leave the loading state wedged.
        for attempt in 0...2 {
            guard let target,
                  target == loadTarget,
                  owns(target),
                  isAuthoritative,
                  let subscriptionToken = installedSubscriptionToken(for: sessionID),
                  let current = snapshot,
                  let before = visibleTranscriptStart,
                  before > 0 else {
                updateTranscriptLoadState(
                    .failed("Earlier messages are not available on this presentation."),
                    for: loadTarget
                )
                return .unavailable
            }
            guard let expectedTotal = visibleTranscriptTotal,
                  let visibleEnd = visibleTranscriptEnd,
                  visibleEnd == expectedTotal else {
                updateTranscriptLoadState(.failed("History bounds are invalid."), for: loadTarget)
                return .failed
            }
            // This lease intentionally excludes eventSequence: ordinary
            // streaming events may advance that cursor while this request is
            // suspended. Structure, runtime, branch, and mounted coverage are
            // exact identities and must not change underneath the page.
            let leasedTarget = target
            let leasedStructureRevision = structureRevision
            let leasedRuntimeGeneration = current.runtimeGeneration
            let leasedLeafEntryID = current.leafEntryId
            let leasedCoverage = mountedTranscriptCoverage
            let request = ChatTranscriptPageRequest(
                sessionID: sessionID,
                presentationGeneration: presentationGeneration,
                runtimeGeneration: leasedRuntimeGeneration,
                before: before,
                expectedTotal: expectedTotal,
                expectedNextEntryID: visibleTranscript.first?.id
            )
            do {
                let response: Response = try await client.request(
                    "session.transcript",
                    Params(
                        sessionId: sessionID,
                        before: before,
                        expectedNextEntryId: visibleTranscript.first?.id,
                        expectedRuntimeGeneration: current.runtimeGeneration,
                        expectedLeafEntryId: current.leafEntryId
                    ),
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled,
                      let currentTarget = self.mountedTarget,
                      currentTarget == leasedTarget,
                      self.isAuthoritative,
                      self.installedSubscriptionToken(for: sessionID) == subscriptionToken,
                      let installed = self.snapshot else {
                    updateTranscriptLoadState(.idle, for: loadTarget)
                    return .unavailable
                }
                // A branch/structure change invalidates the cursor at once;
                // never retry a page against a changed canonical spine. The
                // same exact lease also prevents a replacement runtime, leaf,
                // target, or mounted coverage from accepting stale rows.
                guard self.structureRevision == leasedStructureRevision,
                      installed.runtimeGeneration == leasedRuntimeGeneration,
                      installed.leafEntryId == leasedLeafEntryID,
                      self.mountedTranscriptCoverage == leasedCoverage else {
                    updateTranscriptLoadState(
                        .failed("History changed while loading. Tap to retry."),
                        for: loadTarget
                    )
                    return .stale
                }
                guard request.canInstall(
                    sessionID: currentTarget.sessionID,
                    presentationGeneration: currentTarget.generation,
                    runtimeGeneration: installed.runtimeGeneration,
                    transcriptStart: self.visibleTranscriptStart,
                    transcriptTotal: self.visibleTranscriptTotal,
                    firstTranscriptID: self.visibleTranscript.first?.id
                ) else {
                    if attempt < 2 { continue }
                    updateTranscriptLoadState(
                        .failed("History changed while loading. Tap to retry."),
                        for: loadTarget
                    )
                    return .stale
                }
                let requiresMountedEchoes = before > 0
                guard !requiresMountedEchoes || (
                    response.runtimeGeneration == leasedRuntimeGeneration
                        && response.leafEntryIdPresent
                        && response.leafEntryId == leasedLeafEntryID
                        && Self.admitsTranscriptPageAnchor(
                            expectedNextEntryID: request.expectedNextEntryID,
                            echoedNextEntryID: response.nextEntryId
                        )
                ),
                      request.canInstallPage(
                    start: response.start,
                    end: response.end ?? before,
                    total: response.total,
                    itemCount: response.items.count,
                    visibleItemCount: self.visibleTranscript.count
                ), Self.admitsTranscriptPage(response.items) else {
                    // Repeating the same malformed/stale page cannot converge.
                    // Retry only when the mounted canonical cursor itself moved.
                    updateTranscriptLoadState(
                        .failed("The history page did not match this conversation. Tap to retry."),
                        for: loadTarget
                    )
                    return .stale
                }
                let existingIDs = Set(self.visibleTranscript.map(\.id))
                let pageIDs = Set(response.items.map(\.id))
                guard pageIDs.count == response.items.count,
                      response.items.allSatisfy({ !existingIDs.contains($0.id) }) else {
                    updateTranscriptLoadState(
                        .failed("The history branch changed. Tap to retry."),
                        for: loadTarget
                    )
                    return .stale
                }
                let retainedPrefix = (self.mountedTranscriptWindow?.prefixItems ?? [])
                guard let coverage = self.coverage(
                    for: installed,
                    prefix: response.items + retainedPrefix,
                    start: response.start
                ), coverage.end == (installed.transcriptStart ?? 0) + installed.transcript.count else {
                    updateTranscriptLoadState(.failed("History bounds are invalid."), for: loadTarget)
                    return .stale
                }
                self.mountedTranscriptWindow = MountedTranscriptWindow(
                    coverage: coverage,
                    prefixItems: response.items + retainedPrefix
                )
                advanceChatProjection(canonical: true)
                updateTranscriptLoadState(.idle, for: loadTarget)
                delegate?.sessionPresentationStoreCheckpointCache()
                return .installed
            } catch is CancellationError {
                updateTranscriptLoadState(.idle, for: loadTarget)
                return .unavailable
            } catch let error as GatewayFailure where error.code == "conflict" && attempt < 2 {
                continue
            } catch {
                updateTranscriptLoadState(.failed(error.localizedDescription), for: loadTarget)
                delegate?.sessionPresentationStoreSurface(error)
                return .failed
            }
        }
        updateTranscriptLoadState(
            .failed("History changed while loading. Tap to retry."),
            for: loadTarget
        )
        return .stale
    }

    private func updateTranscriptLoadState(
        _ state: SessionTranscriptLoadState,
        for target: SessionPresentationIdentity
    ) {
        guard transcriptLoadTarget == target else { return }
        transcriptLoadState = state
    }

    static func admitsTranscriptPageAnchor(
        expectedNextEntryID: String?,
        echoedNextEntryID: String?
    ) -> Bool {
        // Mounted paging requires a present, exact canonical boundary echo.
        // A nil expected anchor is retained only for the empty start=0/no-page
        // compatibility path.
        guard let expectedNextEntryID else { return true }
        guard let echoedNextEntryID else { return false }
        return echoedNextEntryID == expectedNextEntryID
    }

    private static func admitsTranscriptPage(_ items: [TranscriptItem]) -> Bool {
        // Page order and adjacency belong to the Gateway's filtered projected
        // branch. Raw canonical parent links can legitimately point through
        // omitted session-info, hidden custom, or extension receipt entries,
        // so they are not evidence that two displayed rows are noncontiguous.
        // The request/response cursor, runtime, leaf, range, total, echoed next
        // projected entry, and unique/non-overlapping IDs provide admission.
        items.count <= ChatTranscriptPageRequest.maximumItemCount
    }

    func retireConnection() {
        attentionReadTask?.cancel()
        attentionReadTask = nil
        pendingAttentionRead = nil
        connectionGeneration &+= 1
        transcriptLoadTarget = nil
        loadingEarlierTranscript = false
        transcriptLoadState = .idle
        deferredEffectsByTarget.removeAll()
        pendingRebaselines.removeAll()
        pendingSubscriptionTokens.removeAll()
        subscribedSessionID = nil
        subscriptionToken = nil
        subscriptionTarget = nil
        commandLoadGeneration &+= 1
        commandCatalogTarget = nil
        synchronization.reset()
        // Keep the last-good snapshot authoritative for the mounted chat, but
        // advance its presentation generation so the retained projection is
        // immediately observable and can accept the next reconnect owner.
        if mountedTarget != nil, snapshot != nil {
            advanceChatProjection(canonical: false)
        }
        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
    }

    func clearProfile() {
        nextPresentationGeneration &+= 1
        let oldTarget = target
        let oldPendingTarget = pendingTarget
        retireNoticeScopes([oldTarget, oldPendingTarget])
        target = nil
        pendingTarget = nil
        snapshot = nil
        mountedTranscriptWindow = nil
        advanceChatProjection(canonical: true)
        isAuthoritative = false
        revokedTarget = nil
        retireConnection()
        clearSecondaryProjection()
    }

    func closeSubscriptionIfInstalled(sessionID: String) async {
        guard subscribedSessionID == sessionID else { return }
        _ = await closeCurrentSubscription()
    }

    func remove(sessionID: String) {
        guard selectedSessionID == sessionID else { return }
        let oldTarget = target
        let oldPendingTarget = pendingTarget
        retireNoticeScopes([oldTarget, oldPendingTarget])
        target = nil
        pendingTarget = nil
        snapshot = nil
        mountedTranscriptWindow = nil
        advanceChatProjection(canonical: true)
        isAuthoritative = false
        if revokedTarget?.sessionID == sessionID { revokedTarget = nil }
        deferredEffectsByTarget = deferredEffectsByTarget.filter { $0.key.sessionID != sessionID }
        retireConnection()
        clearSecondaryProjection()
    }

    func admit(_ event: GatewayEvent) async {
        if event.topic == "session.rebaseline" {
            guard case .sessionRebaseline(let rebaseline) = event.preparation else {
                if let sessionID = event.sessionId,
                   mountedTarget?.sessionID == sessionID,
                   hasInstalledSubscription(for: sessionID) {
                    _ = await synchronize(sessionID, operation: .sessionResync)
                }
                return
            }
            guard event.sessionId == rebaseline.snapshot.sessionId,
                  ownsExactRebaselineOwner(
                    sessionID: rebaseline.snapshot.sessionId,
                    subscriptionToken: rebaseline.subscriptionToken
                  ) else { return }
            let authoritative = rebaseline.snapshot
            switch SessionRebaselineAdmission.evaluate(current: snapshot, incoming: authoritative) {
            case .ignore:
                return
            case .resynchronize:
                if hasInstalledSubscription(for: authoritative.sessionId) {
                    _ = await synchronize(authoritative.sessionId, operation: .sessionResync)
                }
                return
            case .install:
                break
            }
            if !hasInstalledSubscription(for: authoritative.sessionId) {
                if let pending = pendingRebaselines[authoritative.sessionId],
                   !isNewer(authoritative, than: pending.snapshot) { return }
                pendingRebaselines[authoritative.sessionId] = rebaseline
                return
            }
            let replacedRuntime = prepareSecondaryProjectionForRuntimeInstallation(authoritative)
            mountedTranscriptWindow = reconcilePrefix(
                mountedTranscriptWindow,
                from: snapshot,
                into: authoritative
            )
            snapshot = authoritative
            if replacedRuntime {
                Task { [weak self] in await self?.loadCommands(sessionID: authoritative.sessionId) }
            }
            advanceChatProjection(canonical: true)
            isAuthoritative = mountedTarget?.sessionID == authoritative.sessionId
            delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
            delegate?.sessionPresentationStoreCheckpointCache()
            return
        }
        switch synchronization.admit(event) {
        case .deliver(let event):
            guard admitsSequencedEvent(event) else { return }
            let previousResourceRevision = resourceRevision
            if let sessionID = reduce(event) {
                _ = await synchronize(sessionID, operation: .sessionResync)
            } else if resourceRevision != previousResourceRevision,
                      let sessionID = event.sessionId {
                Task { [weak self] in await self?.loadCommands(sessionID: sessionID) }
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
        guard let token = installedSubscriptionToken(for: sessionID),
              let requestedTarget = subscriptionTarget,
              requestedTarget.sessionID == sessionID else { return }
        commandLoadGeneration &+= 1
        let generation = commandLoadGeneration
        commandCatalogTarget = nil
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let commands: [CommandInfo] }
        do {
            let response: Response = try await client.request("session.commands", Params(sessionId: sessionID))
            guard generation == commandLoadGeneration,
                  ownsSubscription(sessionID: sessionID, requestedToken: token),
                  subscriptionTarget == requestedTarget else { return }
            let admitted = try CommandCatalogPolicy.admit(response.commands)
            commands = admitted
            commandCatalogTarget = requestedTarget
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

    private func ownsExactRebaselineOwner(sessionID: String, subscriptionToken: String) -> Bool {
        if hasInstalledSubscription(for: sessionID) {
            return self.subscriptionToken == subscriptionToken
        }
        return pendingSubscriptionTokens[sessionID] == subscriptionToken
    }

    private func isNewer(_ incoming: SessionSnapshot, than current: SessionSnapshot) -> Bool {
        incoming.runtimeGeneration != current.runtimeGeneration
            || incoming.eventSequence > current.eventSequence
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
        mountedTranscriptWindow = nil
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
        commandCatalogTarget = nil
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
        attentionReadTask?.cancel()
        attentionReadTask = nil
        pendingAttentionRead = nil
        let expectedConnectionGeneration = connectionGeneration
        let expectedSubscriptionTarget = subscriptionTarget
        struct Params: Codable { let sessionId, subscriptionToken: String }
        struct Response: Decodable { let closed: Bool }
        let response: Response? = try? await client.request(
            "session.close",
            Params(sessionId: sessionID, subscriptionToken: token),
            timeout: .seconds(5)
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
        if pendingSubscriptionTokens[sessionID] == token { pendingSubscriptionTokens[sessionID] = nil }
        struct Params: Codable { let sessionId, subscriptionToken: String }
        struct Response: Decodable { let closed: Bool }
        let _: Response? = try? await client.request(
            "session.close",
            Params(sessionId: sessionID, subscriptionToken: token),
            timeout: .seconds(5)
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
        let initialConnectionGeneration = connectionGeneration
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
                // A visible presentation and lifecycle reconnect are two views
                // of the same per-session authority. The current leader owns
                // the open/ack/replay transaction. If that owner was retired by
                // a connection epoch handoff, retry under the fresh owner
                // rather than surfacing a transient false result to ChatView.
                let shared = await lease.sharedValue()
                if shared || connectionGeneration == initialConnectionGeneration { return shared }
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
        case failure(GatewayFailure, operationID: String?)
    }

    private func performSynchronization(
        sessionID: String,
        lease: SessionSynchronizationCoordinator.Lease,
        operation: PerformanceOperation
    ) async -> Bool {
        var nextOperation = operation
        let synchronizationConnectionGeneration = connectionGeneration
        for attempt in 0..<3 {
            guard !Task.isCancelled,
                  synchronization.owns(lease),
                  ownsSynchronizationIntent(lease.intent, sessionID: sessionID) else {
                synchronization.complete(lease, outcome: false)
                return false
            }
            switch await performSynchronizationAttempt(
                sessionID: sessionID,
                lease: lease,
                operation: nextOperation,
                retriesInvalidResponse: attempt < 2
            ) {
            case .success:
                delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
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
                    if ownsNotice { delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope) }
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
                    delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
                case .presentation:
                    if showCatchUpNotice {
                        delegate?.sessionPresentationStorePostNotice(
                            Self.sessionCatchUpNotice,
                            replacing: .sessionCatchUp,
                            role: .info,
                            scope: noticeScope
                        )
                    } else {
                        delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
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
                delegate?.sessionPresentationStoreRemoveNotice(.sessionCatchUp, scope: noticeScope)
            case .presentation:
                delegate?.sessionPresentationStorePostNotice(
                    Self.sessionCatchUpNotice,
                    replacing: .sessionCatchUp,
                    role: .info,
                    scope: noticeScope
                )
            }
        }
        return false
    }

    private func performSynchronizationAttempt(
        sessionID: String,
        lease: SessionSynchronizationCoordinator.Lease,
        operation: PerformanceOperation,
        retriesInvalidResponse: Bool
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
            let responseValue = try await client.requestValue(
                "session.open",
                Params(sessionId: sessionID),
                timeout: .seconds(20)
            )
            // session.open creates synchronization ownership before iOS decodes
            // the snapshot. Preserve the independently bounded close token so
            // a malformed snapshot can release that ownership before retrying.
            if let token = responseValue.objectValue?["subscriptionToken"]?.stringValue,
               GatewayTokenAdmissionPolicy.admit(token) {
                provisionalToken = token
                pendingSubscriptionTokens[sessionID] = token
            }
            let response = try GatewayResponseDecoding.decode(
                responseValue,
                as: GatewaySessionOpenResponse.self,
                method: "session.open"
            )
            guard response.session.sessionId == sessionID else {
                throw GatewayFailure(
                    code: "invalid_response",
                    message: "The Gateway returned a different session while opening this conversation.",
                    retryable: false,
                    details: nil
                )
            }
            guard SessionSnapshotQueueAdmissionPolicy.admit(response.session) else {
                throw GatewayFailure(
                    code: "invalid_response",
                    message: "The Gateway returned an invalid queued-message projection.",
                    retryable: false,
                    details: nil
                )
            }
            provisionalToken = response.subscriptionToken
            pendingSubscriptionTokens[sessionID] = response.subscriptionToken
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

            let pendingRebaseline = pendingRebaselines.removeValue(forKey: sessionID)
            var authoritativeResponse: SessionSnapshot
            if let pendingRebaseline,
               isNewer(pendingRebaseline.snapshot, than: response.session) {
                authoritativeResponse = pendingRebaseline.snapshot
            } else {
                authoritativeResponse = response.session
            }
            guard SessionSnapshotQueueAdmissionPolicy.admit(authoritativeResponse) else {
                throw GatewayFailure(
                    code: "invalid_response",
                    message: "The Gateway returned an invalid queued-message projection.",
                    retryable: false,
                    details: nil
                )
            }
            // Resume from the bounded authoritative tail before any optional
            // history work. Paging inside this barrier extends the replay race
            // for active sessions and can turn a usable baseline into repeated
            // open/sync/page/close failures. Older pages remain available after
            // the presentation mounts and never gate conversation availability.
            let mode: SessionSnapshotInstallationMode
            switch lease.intent {
            case .presentation:
                mode = .freshPresentation
            case .reconnect:
                mode = synchronization.consumeFreshInstallRequirement(sessionID: sessionID)
                    ? .freshPresentation : .reconnect
            }
            let previousAuthority = snapshot
            var installed = Self.installingSnapshot(
                current: previousAuthority,
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
            var replayChangedCanonicalChat = false
            var replayRequiresResynchronization = false
            for event in replay {
                if reduce(
                    event,
                    snapshot: &installed,
                    effects: &replayEffects,
                    chatTimelineChanged: &replayChangedChatTimeline,
                    chatCanonicalChanged: &replayChangedCanonicalChat
                ) != nil { replayRequiresResynchronization = true }
            }
            let replayTailSequence = replay.last?.sessionCursor?.eventSequence ?? cursor.eventSequence
            guard !replayRequiresResynchronization,
                  SessionSnapshotQueueAdmissionPolicy.admit(installed),
                  installed.eventSequence == replayTailSequence else {
                if case .freshPresentation = mode { synchronization.requireFreshInstall(sessionID: sessionID) }
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .retry
            }
            if synchronization.consumeRetryRequirement(for: lease) {
                if case .freshPresentation = mode { synchronization.requireFreshInstall(sessionID: sessionID) }
                await closeProvisionalSubscription(
                    sessionID,
                    token: response.subscriptionToken,
                    expectedConnectionGeneration: attemptConnectionGeneration
                )
                result = .discarded
                return .retry
            }
            guard let synchronizationTarget = synchronizationTarget(
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
            let handoffTarget: SessionPresentationIdentity? = if case .reconnect = lease.intent,
                                                                 let pendingTarget,
                                                                 pendingTarget.sessionID == sessionID,
                                                                 owns(pendingTarget) {
                pendingTarget
            } else {
                nil
            }
            let installedTarget = handoffTarget ?? synchronizationTarget
            _ = prepareSecondaryProjectionForRuntimeInstallation(installed)
            mountedTranscriptWindow = if case .freshPresentation = mode {
                nil
            } else {
                reconcilePrefix(mountedTranscriptWindow, from: previousAuthority, into: installed)
            }
            subscribedSessionID = sessionID
            subscriptionToken = response.subscriptionToken
            pendingSubscriptionTokens[sessionID] = nil
            subscriptionTarget = installedTarget
            snapshot = installed
            if commandCatalogTarget != installedTarget {
                Task { [weak self] in await self?.loadCommands(sessionID: sessionID) }
            }
            advanceChatProjection(canonical: true)
            // Acknowledge only the completion revision carried by the exact
            // snapshot that was admitted above. Retry retains that absolute cut;
            // it can never clear a completion that raced after session.open.
            pendingAttentionRead = PendingAttentionRead(
                sessionID: sessionID,
                throughCompletionRevision: response.completionRevision,
                target: installedTarget,
                subscriptionToken: response.subscriptionToken,
                connectionGeneration: attemptConnectionGeneration
            )
            switch lease.intent {
            case .presentation:
                // Final admission, authority installation, fresh mount, and
                // lease release are one MainActor turn. No event can escape the
                // quarantine between these ownership transitions.
                mount(installedTarget)
                isAuthoritative = true
                delegate?.sessionPresentationStoreDidOpen(installedTarget)
                delegate?.sessionPresentationStoreDidPublishSnapshot(installed, target: installedTarget)
                publish(replayEffects, target: installedTarget)
                schedulePendingAttentionRead(targetOverride: installedTarget)
            case .reconnect:
                if handoffTarget != nil {
                    // A visible open joined this reconnect while its quarantine
                    // was active. Transfer the admitted cut before releasing the
                    // shared lease so no replay effect can escape under the old
                    // presentation owner.
                    mount(installedTarget)
                    isAuthoritative = true
                    delegate?.sessionPresentationStoreDidOpen(installedTarget)
                    delegate?.sessionPresentationStoreDidPublishSnapshot(installed, target: installedTarget)
                    publish(replayEffects, target: installedTarget)
                    schedulePendingAttentionRead(targetOverride: installedTarget)
                } else {
                    publish(replayEffects, target: installedTarget)
                    if pendingTarget?.sessionID != sessionID { schedulePendingAttentionRead() }
                }
            }
            synchronization.complete(lease, outcome: true)
            provisionalToken = nil
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
            ), let failureTarget = synchronizationTarget(
                for: lease.intent,
                sessionID: sessionID
            ) else {
                return .failed(showCatchUpNotice: false)
            }
            if let failure = error as? GatewayFailure,
               failure.code == "history_changed",
               retriesInvalidResponse {
                return .retry
            }
            if let failure = error as? GatewayFailure,
               failure.code == "invalid_response",
               retriesInvalidResponse {
                // A runtime snapshot can change while bounded extension
                // activity settles. Retry a malformed projection twice from a
                // fresh session.open; the final failure remains actionable and
                // enters the iOS Logs ring.
                return .retry
            }
            if let failure = error as? GatewayFailure,
               failure.code == "invalid_response",
               case .presentation = lease.intent {
                terminalSynchronizationFailures[failureTarget] = failure
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

    private func schedulePendingAttentionRead(targetOverride: SessionPresentationIdentity? = nil) {
        guard let pending = pendingAttentionRead else { return }
        pendingAttentionRead = nil
        scheduleAttentionRead(
            sessionID: pending.sessionID,
            throughCompletionRevision: pending.throughCompletionRevision,
            target: targetOverride ?? pending.target,
            subscriptionToken: pending.subscriptionToken,
            connectionGeneration: pending.connectionGeneration
        )
    }

    private func scheduleAttentionRead(
        sessionID: String,
        throughCompletionRevision: Int,
        target: SessionPresentationIdentity,
        subscriptionToken: String,
        connectionGeneration: Int
    ) {
        attentionReadTask?.cancel()
        attentionReadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.acknowledgeAttentionRead(
                    sessionID: sessionID,
                    throughCompletionRevision: throughCompletionRevision,
                    target: target,
                    subscriptionToken: subscriptionToken,
                    connectionGeneration: connectionGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func acknowledgeAttentionRead(
        sessionID: String,
        throughCompletionRevision: Int,
        target: SessionPresentationIdentity,
        subscriptionToken expectedToken: String,
        connectionGeneration expectedConnectionGeneration: Int
    ) async throws {
        struct Params: Codable {
            let sessionId: String
            let throughCompletionRevision: Int
        }
        let params = Params(
            sessionId: sessionID,
            throughCompletionRevision: throughCompletionRevision
        )
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard connectionGeneration == expectedConnectionGeneration,
                  subscribedSessionID == sessionID,
                  subscriptionTarget == target,
                  subscriptionToken == expectedToken else {
                throw CancellationError()
            }
            do {
                let _: JSONValue = try await client.requestValue(
                    "session.attention.read",
                    params,
                    timeout: .seconds(8)
                )
                guard connectionGeneration == expectedConnectionGeneration,
                      subscribedSessionID == sessionID,
                      subscriptionTarget == target,
                      subscriptionToken == expectedToken else {
                    throw CancellationError()
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as GatewayFailure {
                // Rolling upgrades can briefly pair a newer app with a Gateway
                // that does not own the additive attention method yet.
                if ["unsupported", "not_found", "method_not_found"].contains(failure.code) { return }
                if failure.retryable && attempt < 2 { continue }
                // Attention convergence is non-blocking for chat. A later
                // reconnect/open retries the same canonical operation.
                return
            } catch {
                if attempt < 2 { continue }
                return
            }
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

    private static func installingExtensionActivities(
        _ snapshot: SessionSnapshot,
        preserving previous: [ExtensionRunActivity],
        previousLiveRevision: Int?,
        previousActivityAsOf: String?
    ) -> SessionSnapshot {
        var result = snapshot
        var admitted = ExtensionActivityAdmissionPolicy.admitted(snapshot.extensionActivities ?? [])
        let staleLiveProjection = previousLiveRevision.map { previous in
            snapshot.liveActivityRevision.map { $0 < previous } ?? true
        } ?? false
        // Preserve all rows across a stale full frame. This closes the compact
        // delta/full-snapshot race without letting an equal/newer authoritative
        // frame retain expired membership. Terminal truth remains latched even
        // when the full frame itself is current.
        for prior in previous {
            guard let index = admitted.firstIndex(where: { $0.stableID == prior.stableID }) else {
                if staleLiveProjection { admitted.append(prior) }
                continue
            }
            let candidate = admitted[index]
            let priorSequence = prior.lifecycle?.sequence
            let candidateSequence = candidate.lifecycle?.sequence
            if staleLiveProjection && (candidateSequence ?? -1) < (priorSequence ?? -1) {
                admitted[index] = prior
                continue
            }
            guard let lifecycle = prior.lifecycle, lifecycle.isTerminal else { continue }
            if candidate.lifecycle?.isTerminal != true || candidate.lifecycle?.state != lifecycle.state {
                admitted[index] = prior
            } else if let sequence = candidate.lifecycle?.sequence, sequence < lifecycle.sequence {
                admitted[index] = prior
            }
        }
        admitted = ExtensionActivityAdmissionPolicy.admitted(
            admitted,
            preserving: Set(admitted.filter(\.isLive).map(\.stableID))
        )
        if staleLiveProjection {
            result.liveActivityRevision = previousLiveRevision
            result.extensionActivityAsOf = previousActivityAsOf
        }
        result.extensionActivities = snapshot.extensionActivities == nil && admitted.isEmpty
            ? nil : admitted
        return result
    }

    private static func installingProcessActivities(
        _ snapshot: SessionSnapshot,
        preserving previous: [SessionProcessActivity],
        previousOverview: SessionProcessOverview?
    ) -> SessionSnapshot {
        var result = snapshot
        var admitted = SessionProcessAdmissionPolicy.admitted(snapshot.processActivities ?? [])
        let stale = previousOverview.map { previous in
            snapshot.processOverview.map { $0.revision < previous.revision } ?? true
        } ?? false
        if stale {
            admitted = previous
            result.processOverview = previousOverview
        } else {
            for prior in previous where prior.lifecycle.state.isTerminal {
                guard let index = admitted.firstIndex(where: { $0.processId == prior.processId }) else { continue }
                let candidate = admitted[index]
                if !candidate.lifecycle.state.isTerminal
                    || candidate.lifecycle.state != prior.lifecycle.state
                    || candidate.lifecycle.sequence < prior.lifecycle.sequence {
                    admitted[index] = prior
                }
            }
        }
        result.processActivities = snapshot.processActivities == nil && admitted.isEmpty
            ? nil : SessionProcessAdmissionPolicy.admitted(admitted)
        return result
    }

    private static func upsertingProcessActivity(
        _ activity: SessionProcessActivity,
        into activities: [SessionProcessActivity]
    ) -> ([SessionProcessActivity], Bool) {
        var result = activities
        guard let index = result.firstIndex(where: { $0.processId == activity.processId }) else {
            result.append(activity)
            return (SessionProcessAdmissionPolicy.admitted(result), true)
        }
        let previous = result[index]
        if previous.lifecycle.state.isTerminal {
            guard activity.lifecycle.state.isTerminal,
                  activity.lifecycle.state == previous.lifecycle.state else { return (activities, false) }
        }
        guard activity.lifecycle.sequence > previous.lifecycle.sequence else { return (activities, false) }
        result[index] = activity
        return (SessionProcessAdmissionPolicy.admitted(result), true)
    }

    private static func upsertingExtensionActivity(
        _ activity: ExtensionRunActivity,
        into activities: [ExtensionRunActivity]
    ) -> ([ExtensionRunActivity], Bool) {
        let key = activity.stableID
        var result = activities
        guard let index = result.firstIndex(where: { $0.stableID == key }) else {
            result.append(activity)
            let prioritized = [activity] + result.filter { $0.stableID != key }
            return (ExtensionActivityAdmissionPolicy.admitted(
                prioritized,
                preserving: Set(prioritized.filter { $0.isLive || $0.stableID == key }.map(\.stableID))
            ), true)
        }
        let previous = result[index]
        let previousLifecycle = previous.lifecycle
        let nextLifecycle = activity.lifecycle
        if let previousLifecycle, previousLifecycle.isTerminal {
            // Terminal truth is latched. Equal/older advisory updates and any
            // attempt to return to a current state are ignored.
            if nextLifecycle?.isTerminal != true || nextLifecycle?.state != previousLifecycle.state { return (activities, false) }
        }
        if let old = previousLifecycle?.sequence, let next = nextLifecycle?.sequence, next <= old { return (activities, false) }
        result[index] = activity
        let prioritized = [activity] + result.filter { $0.stableID != key }
        return (ExtensionActivityAdmissionPolicy.admitted(
            prioritized,
            preserving: Set(prioritized.filter { $0.isLive || $0.stableID == key }.map(\.stableID))
        ), true)
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
        var chatCanonicalChanged = false
        let resync = reduce(
            event,
            snapshot: &current,
            effects: &effects,
            chatTimelineChanged: &chatTimelineChanged,
            chatCanonicalChanged: &chatCanonicalChanged
        )
        snapshot = current
        if chatTimelineChanged { advanceChatProjection(canonical: chatCanonicalChanged) }
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
            if let statusOwners = patch.statusOwners { next.semanticState.statusOwners = statusOwners }
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
        if previousSemantic.hiddenThinkingLabel != next.semanticState.hiddenThinkingLabel {
            chatTimelineChanged = true
        }
        snapshot.extensionPresentation = next
        if let notification = mutation.notification { effects.append(.notice(notification.message, type: notification.type.rawValue)) }
        return .applied
    }

    private func reduce(
        _ event: GatewayEvent,
        snapshot: inout SessionSnapshot,
        effects: inout [ReducerEffect],
        chatTimelineChanged: inout Bool,
        chatCanonicalChanged: inout Bool,
        updatesSecondaryRevisions: Bool = true
    ) -> String? {
        switch event.topic {
        case "session.summary":
            break
        case "session.listChanged":
            effects.append(.catalogRefresh)
        case "session.snapshot":
            guard case .sessionSnapshot(let incoming) = event.preparation else {
                return resyncIfNeeded(event, snapshot: snapshot)
            }
            switch SessionSnapshotEventAdmission.evaluate(
                eventSessionID: event.sessionId,
                hasLiveAuthority: true,
                current: snapshot,
                incoming: incoming
            ) {
            case .install:
                let extensionAdmitted = Self.installingExtensionActivities(
                    incoming,
                    preserving: snapshot.extensionActivities ?? [],
                    previousLiveRevision: snapshot.liveActivityRevision,
                    previousActivityAsOf: snapshot.extensionActivityAsOf
                )
                snapshot = Self.installingProcessActivities(
                    extensionAdmitted,
                    preserving: snapshot.processActivities ?? [],
                    previousOverview: snapshot.processOverview
                )
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
        case "session.compaction":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .compaction(let item)? = event.preparedSessionEvent?.data,
                  item.kind == .compaction,
                  let start = snapshot.transcriptStart,
                  let total = snapshot.transcriptTotal,
                  start >= 0, total >= start,
                  total - start == snapshot.transcript.count,
                  case let (nextTotal, totalOverflow) = total.addingReportingOverflow(1),
                  !totalOverflow,
                  snapshot.leafEntryId == item.parentId,
                  !visibleTranscriptItems(for: snapshot).contains(where: { $0.id == item.id }) else {
                return resyncIfNeeded(event, snapshot: snapshot)
            }
            let previous = snapshot
            let hadMountedPrefix = mountedWindow(for: previous) != nil
            var next = previous
            next.transcript.append(item)
            next.transcriptTotal = nextTotal
            next.leafEntryId = item.id
            let overflow = max(0, next.transcript.count - SessionSnapshot.maximumTranscriptItems)
            if overflow > 0 {
                next.transcript.removeFirst(overflow)
                next.transcriptStart = start + overflow
            }
            let reconciledPrefix = reconcilePrefix(
                mountedTranscriptWindow,
                from: previous,
                into: next
            )
            guard !hadMountedPrefix || reconciledPrefix != nil else { return snapshot.sessionId }
            next.streaming = nil
            advance(&next, envelope)
            snapshot = next
            mountedTranscriptWindow = reconciledPrefix
            chatTimelineChanged = true
            chatCanonicalChanged = true
        case "session.toolProgress":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .toolProgress(let tool)? = event.preparedSessionEvent?.data else { return resyncIfNeeded(event, snapshot: snapshot) }
            if let incomingRevision = tool.liveActivityRevision {
                if let currentRevision = snapshot.liveActivityRevision,
                   incomingRevision < currentRevision {
                    advance(&snapshot, envelope)
                    return nil
                }
                if snapshot.liveActivityRevision == nil || incomingRevision > snapshot.liveActivityRevision! {
                    snapshot.liveActivityRevision = incomingRevision
                    snapshot.extensionActivityAsOf = tool.extensionActivityAsOf
                }
            }
            var installedTool = tool
            if let index = snapshot.toolExecutions.firstIndex(where: { $0.toolCallId == tool.toolCallId }) {
                let currentTool = snapshot.toolExecutions[index]
                if ToolExecutionStatePolicy.shouldReplace(currentTool, with: tool) {
                    installedTool = ToolExecutionStatePolicy.mergingLiveEvidence(from: currentTool, into: tool)
                    snapshot.toolExecutions[index] = installedTool
                    chatTimelineChanged = true
                } else {
                    installedTool = currentTool
                }
            } else {
                snapshot.toolExecutions.append(tool)
                chatTimelineChanged = true
            }
            if let activity = installedTool.extensionActivity,
               ExtensionActivityAdmissionPolicy.admits(activity) {
                let (next, changed) = Self.upsertingExtensionActivity(activity, into: snapshot.extensionActivities ?? [])
                if changed { snapshot.extensionActivities = next; chatTimelineChanged = true }
            }
            if chatTimelineChanged { snapshot.toolExecutions.sort(by: ToolExecutionStatePolicy.orderedBefore) }
            advance(&snapshot, envelope)
        case "session.extensionActivity":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .extensionActivity(let delta)? = event.preparedSessionEvent?.data else {
                return resyncIfNeeded(event, snapshot: snapshot)
            }
            if let currentRevision = snapshot.liveActivityRevision,
               delta.liveActivityRevision < currentRevision {
                advance(&snapshot, envelope)
                return nil
            }
            snapshot.liveActivityRevision = delta.liveActivityRevision
            snapshot.extensionActivityAsOf = delta.extensionActivityAsOf
            let (next, changed) = Self.upsertingExtensionActivity(
                delta.activity,
                into: snapshot.extensionActivities ?? []
            )
            if changed { snapshot.extensionActivities = next }
            // This delta changes only the mounted extension hub. Deliberately
            // do not advance transcript projection or scrolling.
            advance(&snapshot, envelope)
        case "session.processActivity":
            guard let envelope = admitEnvelope(event, snapshot: snapshot),
                  case .processActivity(let delta)? = event.preparedSessionEvent?.data else {
                return resyncIfNeeded(event, snapshot: snapshot)
            }
            let previousRevision = snapshot.processOverview?.revision
            if let previousRevision, delta.processRevision < previousRevision {
                advance(&snapshot, envelope)
                return nil
            }
            guard SessionProcessAdmissionPolicy.admits(delta) else { return snapshot.sessionId }

            let removals = Set(delta.removedProcessIds ?? [])
            var next = (snapshot.processActivities ?? []).filter { !removals.contains($0.processId) }
            if let activity = delta.activity {
                let result = Self.upsertingProcessActivity(activity, into: next)
                // A newly authoritative aggregate cannot be installed around a
                // stale/rejected row. Resynchronize rather than allowing the
                // composer overview and mounted rows to split authority.
                guard result.1 else { return snapshot.sessionId }
                next = result.0
            }
            guard SessionProcessAdmissionPolicy.admitsMountedSubset(
                next,
                overview: delta.overview
            ) else { return snapshot.sessionId }
            snapshot.processOverview = delta.overview
            snapshot.processActivities = next
            // Process output and lifecycle never mutate transcript projection
            // or issue a scroll command.
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
                effects.append(.failure(
                    GatewayFailure(
                        code: "session_operation_failed",
                        message: message,
                        retryable: false,
                        details: nil
                    ),
                    operationID: envelope.data.objectValue?["operationId"]?.stringValue
                ))
            }
            advance(&snapshot, envelope)
        case "session.structureChanged":
            guard let envelope = admitEnvelope(event, snapshot: snapshot) else { return resyncIfNeeded(event, snapshot: snapshot) }
            if updatesSecondaryRevisions {
                // Invalidate mounted transcript coverage before any later
                // snapshot/rebaseline can attempt prefix reconciliation.
                structureRevision &+= 1
                contextRevision &+= 1
                mountedTranscriptWindow = nil
                if envelope.data.objectValue?["branchChanged"]?.boolValue == true {
                    synchronization.requireFreshInstall(sessionID: snapshot.sessionId)
                }
            }
            advance(&snapshot, envelope)
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
                commandLoadGeneration &+= 1
                commandCatalogTarget = nil
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
                let role: InAppNoticeCenter.Role = switch type {
                case "warning": .warning
                case "error": .error
                default: .info
                }
                delegate?.sessionPresentationStorePostNotice(
                    message,
                    replacing: nil,
                    role: role,
                    scope: noticeScope
                )
            case .failure(let failure, let operationID):
                if let operationID, let target {
                    delegate?.sessionPresentationStoreDidFailOperation(
                        operationID: operationID,
                        target: target
                    )
                }
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
            let extensionAdmitted = Self.installingExtensionActivities(
                incoming,
                preserving: snapshot?.extensionActivities ?? [],
                previousLiveRevision: snapshot?.liveActivityRevision,
                previousActivityAsOf: snapshot?.extensionActivityAsOf
            )
            let admitted = Self.installingProcessActivities(
                extensionAdmitted,
                preserving: snapshot?.processActivities ?? [],
                previousOverview: snapshot?.processOverview
            )
            mountedTranscriptWindow = reconcilePrefix(
                mountedTranscriptWindow,
                from: snapshot,
                into: admitted
            )
            snapshot = admitted
            advanceChatProjection(canonical: true)
            if admitted.transcriptStart == incoming.transcriptStart,
               admitted.transcript.count == incoming.transcript.count {
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
        if pendingTarget == nil,
           isAuthoritative,
           let target,
           let snapshot {
            delegate?.sessionPresentationStoreDidPublishSnapshot(snapshot, target: target)
        }
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
            guard let current,
                  current.sessionId == authoritative.sessionId,
                  current.runtimeGeneration == authoritative.runtimeGeneration else { return authoritative }
            guard authoritative.eventSequence >= current.eventSequence else { return current }
            let extensionAdmitted = installingExtensionActivities(
                authoritative,
                preserving: current.extensionActivities ?? [],
                previousLiveRevision: current.liveActivityRevision,
                previousActivityAsOf: current.extensionActivityAsOf
            )
            return installingProcessActivities(
                extensionAdmitted,
                preserving: current.processActivities ?? [],
                previousOverview: current.processOverview
            )
        }
    }

    static let sessionCatchUpNotice = "Live session view is catching up; the run continues on your Mac."

    #if HOSTED_TEST
    func installHostedPresentationTargets(
        target: SessionPresentationIdentity?,
        pending: SessionPresentationIdentity?
    ) {
        self.target = target
        pendingTarget = pending
    }

    func emitHostedNoticeForTesting() {
        delegate?.sessionPresentationStorePostNotice(
            "hosted",
            replacing: nil,
            role: .info,
            scope: noticeScope
        )
    }

    func mountHostedPresentationForTesting(_ target: SessionPresentationIdentity) {
        mount(target)
    }

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
        mountedTranscriptWindow = nil
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
        let tailStart = authoritativeTail.transcriptStart ?? 0
        let prefixCount = visible.transcript.count - authoritativeTail.transcript.count
        guard prefixCount >= 0,
              visible.transcript.suffix(authoritativeTail.transcript.count).map(\.id) == authoritativeTail.transcript.map(\.id),
              visible.transcriptStart == authoritativeTail.transcriptStart.map({ $0 - prefixCount }),
              prefixCount == max(0, tailStart - (visible.transcriptStart ?? tailStart)),
              let coverage = coverage(for: authoritativeTail, prefix: Array(visible.transcript.prefix(prefixCount))) else { return }
        snapshot = authoritativeTail
        mountedTranscriptWindow = MountedTranscriptWindow(
            coverage: coverage,
            prefixItems: Array(visible.transcript.prefix(prefixCount))
        )
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
        mountedTranscriptWindow = reconcilePrefix(
            mountedTranscriptWindow,
            from: self.snapshot,
            into: snapshot
        )
        self.snapshot = snapshot
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
        transcriptLoadTarget = nil
        loadingEarlierTranscript = false
        transcriptLoadState = .idle
        self.snapshot = snapshot
        mountedTranscriptWindow = nil
        advanceChatProjection(canonical: true)
        isAuthoritative = true
        if revokedTarget == target { revokedTarget = nil }
    }
    #endif
}
