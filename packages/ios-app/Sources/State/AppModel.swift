import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    enum SessionSnapshotInstallMode { case freshPresentation, reconnect }

    enum ConnectionState: Equatable {
        case unpaired, connecting, connected, reconnecting, unauthorized, offline(String)
    }

    struct PendingAttachment: Identifiable, Hashable {
        let id: String
        let name: String
        let mimeType: String
        let size: Int
        let previewData: Data?
    }

    struct AuthPromptState: Identifiable, Hashable {
        enum Kind: String { case text, secret, select, manualCode = "manual_code" }
        let id: String
        let operationId: String
        let kind: Kind
        let message: String
        let placeholder: String?
        let options: [Option]
        struct Option: Hashable, Identifiable { let id: String; let label: String; let description: String? }
    }

    struct AuthEventState: Identifiable, Hashable {
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
        var id: String { operationId }
    }

    struct SessionNavigationRoute: Identifiable, Hashable {
        let sessionID: String
        let editorText: String?
        var id: String { sessionID }
    }

    struct SessionPresentationTarget: Hashable {
        let sessionID: String
        let generation: Int
    }

    struct EditorRequest: Identifiable, Hashable {
        enum Action: String { case set, paste }
        let sessionId: String
        let presentationGeneration: Int
        let revision: Int
        let action: Action
        let text: String
        let fullText: String
        var id: String { "\(sessionId):\(presentationGeneration):\(revision)" }
    }

    struct SessionOpenResponse: Decodable {
        let session: SessionSnapshot
        let syncToken: String
        let subscriptionToken: String

        private enum CodingKeys: String, CodingKey { case session, syncToken, subscriptionToken }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            session = try container.decode(SessionSnapshot.self, forKey: .session)
            syncToken = try container.decode(String.self, forKey: .syncToken)
            // Early protocol-v2 gateways use the synchronization token as the
            // subscription identity. New gateways expose that same value under
            // an explicit field so stale closes can be rejected end to end.
            subscriptionToken = try container.decodeIfPresent(String.self, forKey: .subscriptionToken) ?? syncToken
        }
    }
    private struct SessionMutationResponse: Codable { let sessionId: String }
    private struct CommandStatusParams: Codable { let method, commandId: String }
    private struct CommandStatusResponse: Decodable { let status: String; let result: JSONValue? }
    private struct PairingAttempt {
        let id: UUID
        let task: Task<Void, Error>
        let previousConnectionState: ConnectionState
    }

    private enum ConnectionLifecyclePhase {
        case active(Int)
        case transitioning(Int)
        case tornDown(Int)

        var generation: Int {
            switch self {
            case .active(let generation), .transitioning(let generation), .tornDown(let generation):
                generation
            }
        }

        var admitsWork: Bool {
            if case .active = self { return true }
            return false
        }
    }

    typealias PairingCommit = @MainActor @Sendable (GatewayProfile, String) throws -> Void
    typealias ProfileTokenLookup = @MainActor @Sendable (GatewayProfile) -> String?

    let client: GatewayClient
    let profiles: GatewayProfileStore
    private let cache: SnapshotCache
    private let clock: MonotonicClock
    private let reconnectDelayPolicy: ReconnectDelayPolicy
    private let uuidSource: UUIDSource
    private let performanceSignposts: any PerformanceSignposting
    private let pairer: GatewayPairer
    private let pairingCommit: PairingCommit
    private let profileTokenLookup: ProfileTokenLookup

    var connectionState: ConnectionState = .unpaired
    /// False only while the first launch credential/connection decision is
    /// unresolved. The UI must not infer "unpaired" from the temporary default.
    var hasResolvedLaunchState = false
    var gatewayInfo: GatewayInfo?
    private var gatewayConnectionID: Int?
    var sessions: [SessionSummary] = []
    var selectedSessionID: String? {
        didSet {
            guard selectedSessionID != oldValue else { return }
            context = nil
            resources = nil
            sessionTree = []
            commands = []
        }
    }
    var snapshots: [String: SessionSnapshot] = [:]
    var sessionStructureRevisions: [String: Int] = [:]
    var sessionContextRevisions: [String: Int] = [:]
    var sessionResourceRevisions: [String: Int] = [:]
    var settingsInvalidationGeneration = 0
    var providerInvalidationGeneration = 0
    var packageInvalidationGeneration = 0
    var customModelInvalidationGeneration = 0
    var trustRevision = 0
    var providerCatalogByTarget: [ProviderCatalogTarget: ProviderCatalog] = [:]
    var pairedDevices: [PairedDevice] = []
    var legacyImportAvailable = false
    var legacyImportedCount = 0
    var workspace: WorkspaceListing?
    var defaultWorkspace: String?
    private var revokedPresentationTargets = Set<SessionPresentationTarget>()
    private var pendingAttachmentsByTarget = PresentationOwnedStore<
        SessionPresentationTarget,
        [PendingAttachment]
    >()
    var authPrompt: AuthPromptState?
    var authEvent: AuthEventState?
    private var editorRequestByTarget = PresentationOwnedStore<
        SessionPresentationTarget,
        EditorRequest
    >()
    private var noticeStore = GlobalNoticeStore()
    var latestNotice: String? { noticeStore.latest }
    var lastError: String?
    var onboardingError: String?
    var settingsByTarget: [SettingsTarget: JSONValue] = [:]
    var context: JSONValue?
    var sessionTree: [SessionTreeNode] = []
    var loadingEarlierTranscript = false
    private(set) var authoritativeSessionIDs: Set<String> = []
    var commands: [CommandInfo] = []
    var resources: JSONValue?
    var packageInventoryByTarget: [PackageConfigurationTarget: PackageInventory] = [:]
    var packageUpdatesByTarget: [PackageConfigurationTarget: [PackageUpdate]] = [:]
    var customModelsByTarget: [CustomModelTarget: JSONValue] = [:]
    private var terminalState = TerminalCoordinator()
    var setupComplete: Bool {
        get {
            if UserDefaults.standard.object(forKey: "tronSetupComplete.v1") != nil {
                return UserDefaults.standard.bool(forKey: "tronSetupComplete.v1")
            }
            return UserDefaults.standard.bool(forKey: "piSetupComplete.v1")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "tronSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "piSetupComplete.v1")
        }
    }

    private var lifecyclePhase: ConnectionLifecyclePhase = .active(0)
    private var completedLifecycleTransitionGeneration = 0
    private var lifecycleTransitionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptGeneration = 0
    private var reconnectCanBeAccelerated = false
    private var pairingAttempt: PairingAttempt?
    private var settingsLoadGenerationByTarget: [SettingsTarget: Int] = [:]
    private var providerLoadGenerationByTarget: [ProviderCatalogTarget: Int] = [:]
    private var providerCatalogTargetByAuthOperation: [String: ProviderCatalogTarget] = [:]
    private var packageLoadGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
    private var packageUpdateGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
    private var customModelLoadGenerationByTarget: [CustomModelTarget: Int] = [:]
    private var deviceLoadGeneration = 0
    private var legacyImportLoadGeneration = 0
    private var foregroundReconciliationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var subscribedSessionID: String?
    private var subscriptionTokenBySession: [String: String] = [:]
    private let sessionSynchronization = SessionSynchronizationCoordinator()
    private var hiddenSessionIDs: Set<String> = []
    private var locallyCreatedUnindexedSessionIDs: Set<String> = []
    private var liveSessionSummaryUpdates: [String: SessionSummaryUpdate] = [:]
    private var terminalCleanupGeneration = 0
    private var terminalCleanupTasks: [Int: Task<Void, Never>] = [:]
    private var workspaceLoadGeneration = 0
    private var sessionCatalogLoadOwner = SessionCatalogLoadOwner()
    private var presentationOpenGeneration = 0
    private var mountedPresentationGenerationBySession: [String: Int] = [:]

    init(
        client: GatewayClient = GatewayClient(),
        profiles: GatewayProfileStore = GatewayProfileStore(),
        cache: SnapshotCache = SnapshotCache(),
        clock: MonotonicClock = .continuous,
        reconnectDelayPolicy: ReconnectDelayPolicy = .standard,
        uuidSource: UUIDSource = .random,
        pairer: GatewayPairer = GatewayPairer(),
        pairingCommit: PairingCommit? = nil,
        profileTokenLookup: ProfileTokenLookup? = nil,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.client = client
        self.profiles = profiles
        self.cache = cache
        self.clock = clock
        self.reconnectDelayPolicy = reconnectDelayPolicy
        self.uuidSource = uuidSource
        self.performanceSignposts = performanceSignposts
        self.pairer = pairer
        self.pairingCommit = pairingCommit ?? { profile, token in
            try profiles.save(profile, token: token)
        }
        self.profileTokenLookup = profileTokenLookup ?? { profile in
            profiles.token(for: profile)
        }
        #if HOSTED_TEST
        if ProcessInfo.processInfo.arguments.contains("--tron-reset-ui-test-state") {
            for profile in profiles.profiles { profiles.remove(profile) }
            UserDefaults.standard.removeObject(forKey: "tronSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "piSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "defaultWorkspace.v1")
        }
        #endif
        let events = client.events
        eventTask = Task { [weak self, events] in
            for await delivery in events {
                await self?.handle(delivery.event, connectionID: delivery.connectionID)
            }
        }
    }

    var selectedSnapshot: SessionSnapshot? {
        selectedSessionID.flatMap { snapshots[$0] }
    }

    func authoritativeSnapshot(for sessionID: String) -> SessionSnapshot? {
        guard authoritativeSessionIDs.contains(sessionID) else { return nil }
        return snapshots[sessionID]
    }

    #if HOSTED_TEST
    func installHostedAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        selectedSessionID = snapshot.sessionId
        snapshots[snapshot.sessionId] = snapshot
        authoritativeSessionIDs.insert(snapshot.sessionId)
    }

    func connectHostedGateway(profile: GatewayProfile, token: String) async throws {
        let connection = try await client.connectForLifecycle(profile: profile, token: token)
        gatewayConnectionID = connection.id
        try await client.activateEvents(connectionID: connection.id)
        gatewayInfo = connection.info
        connectionState = .connected
    }
    #endif

    func presentationGeneration(for sessionID: String) -> Int? {
        mountedPresentationGenerationBySession[sessionID]
    }

    func presentationTarget(for sessionID: String) -> SessionPresentationTarget? {
        mountedPresentationGenerationBySession[sessionID].map {
            SessionPresentationTarget(sessionID: sessionID, generation: $0)
        }
    }

    func ownsPresentation(_ target: SessionPresentationTarget) -> Bool {
        Self.admitsPresentationIntake(
            mountedGeneration: mountedPresentationGenerationBySession[target.sessionID],
            requestedGeneration: target.generation,
            isRevoked: revokedPresentationTargets.contains(target)
        )
    }

    func revokePresentationIntake(_ target: SessionPresentationTarget) {
        guard Self.ownsPresentation(
            mountedGeneration: mountedPresentationGenerationBySession[target.sessionID],
            requestedGeneration: target.generation
        ) else { return }
        revokedPresentationTargets.insert(target)
    }

    func pendingAttachments(for target: SessionPresentationTarget) -> [PendingAttachment] {
        pendingAttachmentsByTarget[target] ?? []
    }

    func editorRequest(for target: SessionPresentationTarget) -> EditorRequest? {
        editorRequestByTarget[target]
    }

    func consumeEditorRequest(_ request: EditorRequest, for target: SessionPresentationTarget) {
        guard editorRequestByTarget[target]?.id == request.id else { return }
        editorRequestByTarget[target] = nil
    }

    var mountedPresentationTarget: SessionPresentationTarget? {
        Self.soleAdmittedPresentationTarget(
            generations: mountedPresentationGenerationBySession,
            revoked: revokedPresentationTargets
        )
    }

    static func soleAdmittedPresentationTarget(
        generations: [String: Int],
        revoked: Set<SessionPresentationTarget>
    ) -> SessionPresentationTarget? {
        let targets = generations.compactMap { sessionID, generation in
            let target = SessionPresentationTarget(sessionID: sessionID, generation: generation)
            return revoked.contains(target) ? nil : target
        }
        return targets.count == 1 ? targets[0] : nil
    }

    func sessionStructureRevision(for sessionID: String) -> Int {
        sessionStructureRevisions[sessionID] ?? 0
    }

    func sessionContextRevision(for sessionID: String) -> Int {
        sessionContextRevisions[sessionID] ?? 0
    }

    func sessionResourceRevision(for sessionID: String) -> Int {
        sessionResourceRevisions[sessionID] ?? 0
    }

    func settings(for target: SettingsTarget) -> JSONValue? {
        settingsByTarget[target]
    }

    func configuredDefaultModel(for target: SettingsTarget) -> ModelRef? {
        guard let model = settings(for: target)?.objectValue?["effective"]?.objectValue?["defaultModel"]?.objectValue,
              let provider = model["provider"]?.stringValue,
              let id = model["id"]?.stringValue else { return nil }
        return ModelRef(provider: provider, id: id)
    }

    func providerCatalog(for target: ProviderCatalogTarget) -> ProviderCatalog? {
        providerCatalogByTarget[target]
    }

    func preferredAvailableModel(for target: ProviderCatalogTarget) -> ModelRef? {
        let available = providerCatalog(for: target)?.models.filter(\.available) ?? []
        return available.first(where: { $0.provider == "openai-codex" && $0.id == "gpt-5.6-sol" })?.ref
            ?? available.first?.ref
    }

    var visibleSessions: [SessionSummary] {
        SessionSummary.dashboardSessions(sessions).filter { !hiddenSessionIDs.contains($0.id) }
    }

    func postNotice(_ message: String, replacing key: GlobalNoticeKey? = nil) {
        noticeStore.post(message, replacing: key)
    }

    func removeNotice(_ key: GlobalNoticeKey) {
        noticeStore.remove(key)
    }

    func dismissNotices() {
        noticeStore.removeAll()
    }

    func start() async {
        guard lifecyclePhase.admitsWork,
              connectionState != .connecting,
              connectionState != .connected,
              connectionState != .reconnecting else { return }
        guard let profile = profiles.selected, let token = profileTokenLookup(profile) else {
            connectionState = .unpaired
            hasResolvedLaunchState = true
            return
        }
        let generation = lifecyclePhase.generation
        await loadCache(profileID: profile.id, lifecycleGeneration: generation)
        guard admitsLifecycle(generation) else { return }
        await connect(profile: profile, token: token, lifecycleGeneration: generation)
        guard admitsLifecycle(generation) else { return }
        hasResolvedLaunchState = true
    }

    func becameActive() {
        guard lifecyclePhase.admitsWork else { return }
        guard connectionState == .connected else {
            if connectionState != .connecting {
                requestReconnect(immediate: true, replaceExisting: true)
            }
            return
        }
        // Scene activation can be delivered more than once while system network
        // paths are also resuming. One reconciliation owns that boundary so two
        // session.open handshakes cannot race each other.
        guard foregroundReconciliationTask == nil else { return }
        let generation = lifecyclePhase.generation
        foregroundReconciliationTask = Task { [weak self] in
            await self?.reconcileForegroundState(lifecycleGeneration: generation)
            guard let self, self.admitsLifecycle(generation) else { return }
            self.foregroundReconciliationTask = nil
        }
    }

    func pair(_ invitation: PairingInvitation) async throws {
        guard lifecyclePhase.admitsWork else { throw CancellationError() }
        let previousConnectionState = pairingAttempt?.previousConnectionState ?? connectionState
        invalidatePairingAttempt()
        let lifecycleGeneration = lifecyclePhase.generation
        let attemptID = uuidSource.next()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performPair(invitation, attemptID: attemptID)
        }
        pairingAttempt = PairingAttempt(
            id: attemptID,
            task: task,
            previousConnectionState: previousConnectionState
        )
        defer {
            if pairingAttempt?.id == attemptID { pairingAttempt = nil }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if pairingAttempt?.id == attemptID, admitsLifecycle(lifecycleGeneration) {
                connectionState = previousConnectionState
            }
            throw error
        }
    }

    private func performPair(_ invitation: PairingInvitation, attemptID: UUID) async throws {
        connectionState = .connecting
        let name = UIDevice.current.name
        let (profile, token) = try await pairer.pair(invitation, deviceName: name)
        try requirePairingAttempt(attemptID)
        try pairingCommit(profile, token)
        try requirePairingAttempt(attemptID)
        let generation = await beginConnectionTransition(invalidatePairing: false)
        try requirePairingAttempt(attemptID)
        guard lifecyclePhase.generation == generation else { throw CancellationError() }
        finishConnectionTransition(generation)
        await connect(
            profile: profile,
            token: token,
            pairingAttemptID: attemptID,
            lifecycleGeneration: generation
        )
        try requirePairingAttempt(attemptID)
        try requireLifecycle(generation)
        hasResolvedLaunchState = true
    }

    private func requirePairingAttempt(_ id: UUID) throws {
        try Task.checkCancellation()
        guard pairingAttempt?.id == id else { throw CancellationError() }
    }

    private func invalidatePairingAttempt() {
        let task = pairingAttempt?.task
        pairingAttempt = nil
        task?.cancel()
    }

    private func admitsLifecycle(_ generation: Int) -> Bool {
        lifecyclePhase.admitsWork && lifecyclePhase.generation == generation
    }

    private func requireLifecycle(_ generation: Int) throws {
        try Task.checkCancellation()
        guard admitsLifecycle(generation) else { throw CancellationError() }
    }

    private func requireConnection(_ connectionID: Int?) throws {
        try Task.checkCancellation()
        guard let connectionID, gatewayConnectionID == connectionID else { throw CancellationError() }
    }

    @discardableResult
    private func beginConnectionTransition(
        final: Bool = false,
        invalidatePairing: Bool = true
    ) async -> Int {
        let generation = lifecyclePhase.generation &+ 1
        lifecyclePhase = final ? .tornDown(generation) : .transitioning(generation)
        if invalidatePairing { invalidatePairingAttempt() }

        let reconnect = reconnectTask
        let foreground = foregroundReconciliationTask
        let refresh = refreshTask
        let events = final ? eventTask : nil
        let terminalCleanup = Array(terminalCleanupTasks.values)
        reconnectTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        foregroundReconciliationTask = nil
        refreshTask = nil
        terminalCleanupTasks.removeAll()
        reconnect?.cancel()
        foreground?.cancel()
        refresh?.cancel()
        terminalCleanup.forEach { $0.cancel() }
        if final {
            events?.cancel()
            eventTask = nil
        }

        invalidateProfileScopedLoads()
        invalidateSessionConnectionOwnership()
        clearGatewayProjection()
        await client.close()
        await reconnect?.value
        await foreground?.value
        await refresh?.value
        for task in terminalCleanup { await task.value }
        await events?.value
        completeLifecycleTransition(generation)
        return generation
    }

    private func waitForLifecycleTransition(_ generation: Int) async {
        guard completedLifecycleTransitionGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            lifecycleTransitionWaiters[generation, default: []].append(continuation)
        }
    }

    private func completeLifecycleTransition(_ generation: Int) {
        completedLifecycleTransitionGeneration = max(completedLifecycleTransitionGeneration, generation)
        let completed = lifecycleTransitionWaiters.keys.filter { $0 <= generation }
        for key in completed {
            let waiters = lifecycleTransitionWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter.resume() }
        }
    }

    private func finishConnectionTransition(_ generation: Int) {
        guard case .transitioning(let currentGeneration) = lifecyclePhase,
              currentGeneration == generation else { return }
        lifecyclePhase = .active(generation)
    }

    private func cancelReconnect() {
        let task = reconnectTask
        reconnectTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        task?.cancel()
    }

    private func admitsReconnect(lifecycleGeneration: Int, attemptGeneration: Int) -> Bool {
        admitsLifecycle(lifecycleGeneration) && reconnectAttemptGeneration == attemptGeneration
    }

    private func requireReconnect(lifecycleGeneration: Int, attemptGeneration: Int) throws {
        try Task.checkCancellation()
        guard admitsReconnect(
            lifecycleGeneration: lifecycleGeneration,
            attemptGeneration: attemptGeneration
        ) else { throw CancellationError() }
    }

    private func finishReconnect(lifecycleGeneration: Int, attemptGeneration: Int) {
        guard admitsReconnect(
            lifecycleGeneration: lifecycleGeneration,
            attemptGeneration: attemptGeneration
        ) else { return }
        reconnectTask = nil
        reconnectCanBeAccelerated = false
    }

    private func invalidateProfileScopedLoads() {
        sessionCatalogLoadOwner.invalidate()
        workspaceLoadGeneration &+= 1
        deviceLoadGeneration &+= 1
        legacyImportLoadGeneration &+= 1
        settingsLoadGenerationByTarget = settingsLoadGenerationByTarget.mapValues { $0 &+ 1 }
        providerLoadGenerationByTarget = providerLoadGenerationByTarget.mapValues { $0 &+ 1 }
        packageLoadGenerationByTarget = packageLoadGenerationByTarget.mapValues { $0 &+ 1 }
        packageUpdateGenerationByTarget = packageUpdateGenerationByTarget.mapValues { $0 &+ 1 }
        customModelLoadGenerationByTarget = customModelLoadGenerationByTarget.mapValues { $0 &+ 1 }
    }

    private func clearGatewayProjection() {
        gatewayInfo = nil
        gatewayConnectionID = nil
        sessions.removeAll()
        snapshots.removeAll()
        authoritativeSessionIDs.removeAll()
        selectedSessionID = nil
        pairedDevices.removeAll()
        legacyImportAvailable = false
        legacyImportedCount = 0
        workspace = nil
        hiddenSessionIDs.removeAll()
        locallyCreatedUnindexedSessionIDs.removeAll()
        providerCatalogByTarget.removeAll()
        settingsByTarget.removeAll()
        packageInventoryByTarget.removeAll()
        packageUpdatesByTarget.removeAll()
        customModelsByTarget.removeAll()
        providerCatalogTargetByAuthOperation.removeAll()
        authPrompt = nil
        authEvent = nil
        lastError = nil
        onboardingError = nil
        presentationOpenGeneration &+= 1
        mountedPresentationGenerationBySession.removeAll()
        revokedPresentationTargets.removeAll()
        pendingAttachmentsByTarget = .init()
        editorRequestByTarget = .init()
        clearLiveConnectionProjection()
    }

    func switchGateway(_ profile: GatewayProfile) async {
        if case .tornDown = lifecyclePhase { return }
        let generation = await beginConnectionTransition()
        guard lifecyclePhase.generation == generation else { return }
        guard let token = profileTokenLookup(profile) else {
            finishConnectionTransition(generation)
            connectionState = .unpaired
            hasResolvedLaunchState = true
            lastError = "This gateway no longer has a Keychain token. Pair it again."
            return
        }
        profiles.select(profile)
        finishConnectionTransition(generation)
        await loadCache(profileID: profile.id, lifecycleGeneration: generation)
        guard admitsLifecycle(generation) else { return }
        await connect(profile: profile, token: token, lifecycleGeneration: generation)
    }

    func forgetCurrentGateway() async {
        if case .tornDown = lifecyclePhase { return }
        let generation = await beginConnectionTransition()
        guard lifecyclePhase.generation == generation else { return }
        if let profile = profiles.selected { profiles.remove(profile) }
        finishConnectionTransition(generation)
        setupComplete = false
        connectionState = .unpaired
        hasResolvedLaunchState = true
    }

    func teardown() async {
        if case .tornDown(let generation) = lifecyclePhase {
            await waitForLifecycleTransition(generation)
            return
        }
        let generation = await beginConnectionTransition(final: true)
        guard case .tornDown(let currentGeneration) = lifecyclePhase,
              currentGeneration == generation else { return }
        connectionState = .unpaired
        hasResolvedLaunchState = true
    }

    private func connect(
        profile: GatewayProfile,
        token: String,
        pairingAttemptID: UUID? = nil,
        lifecycleGeneration: Int? = nil
    ) async {
        let generation = lifecycleGeneration ?? lifecyclePhase.generation
        guard admitsLifecycle(generation) else { return }
        connectionState = .connecting
        do {
            let connection = try await client.connectForLifecycle(profile: profile, token: token)
            try requireLifecycle(generation)
            if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
            gatewayConnectionID = connection.id
            try await client.activateEvents(connectionID: connection.id)
            try requireLifecycle(generation)
            gatewayInfo = connection.info
            invalidateSessionConnectionOwnership()
            cancelReconnect()
            await refreshAll()
            try requireLifecycle(generation)
            if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
            await reattachTerminals()
            try requireLifecycle(generation)
            if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
            connectionState = .connected
        } catch {
            guard admitsLifecycle(generation) else { return }
            if let pairingAttemptID, (try? requirePairingAttempt(pairingAttemptID)) == nil { return }
            if let failure = error as? GatewayFailure, failure.code == "unauthenticated" {
                connectionState = .unauthorized
                lastError = failure.message
            } else if !(error is CancellationError) {
                connectionState = .offline(error.localizedDescription)
                scheduleReconnect()
            }
        }
    }

    private func requestReconnect(immediate: Bool = false, replaceExisting: Bool = false) {
        guard lifecyclePhase.admitsWork, profiles.selected != nil else { return }
        if replaceExisting, reconnectTask != nil {
            guard reconnectCanBeAccelerated else { return }
            cancelReconnect()
        }
        guard reconnectTask == nil else { return }
        connectionState = .reconnecting
        scheduleReconnect(immediate: immediate)
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard lifecyclePhase.admitsWork, profiles.selected != nil, reconnectTask == nil else { return }
        let lifecycleGeneration = lifecyclePhase.generation
        reconnectAttemptGeneration &+= 1
        let attemptGeneration = reconnectAttemptGeneration
        let clock = self.clock
        let delayPolicy = reconnectDelayPolicy
        reconnectCanBeAccelerated = !immediate
        reconnectTask = Task { [weak self] in
            do {
                if !immediate {
                    try await clock.sleep(delayPolicy.delay(nominalSeconds: delayPolicy.initialSeconds))
                    guard let self, self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ) else { return }
                    self.reconnectCanBeAccelerated = false
                }
                var nominalDelay = delayPolicy.initialSeconds
                while !Task.isCancelled {
                    guard let self, self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ) else { return }
                    self.connectionState = .reconnecting
                    do {
                        let connection = try await self.client.reconnectForLifecycle()
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.gatewayConnectionID = connection.id
                        try await self.client.activateEvents(connectionID: connection.id)
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.gatewayInfo = connection.info
                        self.invalidateSessionConnectionOwnership()
                        await self.refreshAll()
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        await self.restoreMountedPresentationAfterReconnect()
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        await self.reattachTerminals()
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.connectionState = .connected
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch let failure as GatewayFailure where failure.code == "unauthenticated" {
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.connectionState = .unauthorized
                        self.lastError = failure.message
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.connectionState = .offline(error.localizedDescription)
                        self.reconnectCanBeAccelerated = true
                        try await clock.sleep(delayPolicy.delay(nominalSeconds: nominalDelay))
                        guard self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.reconnectCanBeAccelerated = false
                        nominalDelay = delayPolicy.nextNominalSeconds(after: nominalDelay)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func restoreMountedPresentationAfterReconnect() async {
        guard let target = mountedPresentationTarget else { return }
        _ = await synchronizeSession(
            target.sessionID,
            presentationGeneration: target.generation
        )
    }

    private func reconcileForegroundState(lifecycleGeneration: Int) async {
        do {
            try await client.ensureResponsive()
            try requireLifecycle(lifecycleGeneration)
            guard await refreshSessions(surfacingErrors: false) else {
                throw GatewayFailure(code: "disconnected", message: "The Mac gateway connection is resuming.", retryable: true, details: nil)
            }
            try requireLifecycle(lifecycleGeneration)
            if let target = mountedPresentationTarget,
               !(await synchronizeSession(
                    target.sessionID,
                    presentationGeneration: target.generation
               )) {
                throw GatewayFailure(code: "sync_failed", message: "The live session is resuming.", retryable: true, details: nil)
            }
            try requireLifecycle(lifecycleGeneration)
            await reattachTerminals()
            try requireLifecycle(lifecycleGeneration)
        } catch is CancellationError {
            return
        } catch {
            guard admitsLifecycle(lifecycleGeneration) else { return }
            invalidateSessionConnectionOwnership()
            requestReconnect(immediate: true, replaceExisting: true)
        }
    }

    func refreshAll(
        settingsTarget: SettingsTarget = .global,
        providerTarget: ProviderCatalogTarget = .global
    ) async {
        await refreshSessions()
        async let providerLoad: Bool = refreshProviders(target: providerTarget)
        async let settingLoad: Bool = refreshSettings(target: settingsTarget)
        async let deviceLoad: Void = refreshDevices()
        _ = await (providerLoad, settingLoad, deviceLoad)
    }

    @discardableResult
    func refreshSessions(surfacingErrors: Bool = true) async -> Bool {
        struct Params: Encodable { let cursor: String?; let limit: Int; let scope: String }
        struct Response: Decodable { let sessions: [SessionSummary]; let nextCursor: String?; let listRevision: Int }
        let loadGeneration = sessionCatalogLoadOwner.begin()
        do {
            var all: [SessionSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            var expectedRevision: Int?
            repeat {
                let response: Response = try await client.request(
                    "session.list",
                    Params(cursor: cursor, limit: 200, scope: "all")
                )
                guard sessionCatalogLoadOwner.admits(loadGeneration) else { return false }
                if let expectedRevision, expectedRevision != response.listRevision {
                    throw GatewayFailure(
                        code: "pagination_changed",
                        message: "Sessions changed while loading the dashboard.",
                        retryable: true,
                        details: nil
                    )
                }
                expectedRevision = response.listRevision
                all.append(contentsOf: response.sessions)
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw GatewayFailure(
                        code: "invalid_pagination",
                        message: "Tron returned a repeated session cursor.",
                        retryable: true,
                        details: nil
                    )
                }
            } while cursor != nil
            guard sessionCatalogLoadOwner.admits(loadGeneration) else { return false }
            let ids = Set(all.map(\.id))
            liveSessionSummaryUpdates = liveSessionSummaryUpdates.filter { ids.contains($0.key) }
            sessions = all.map { summary in
                guard let update = liveSessionSummaryUpdates[summary.id],
                      update.summaryRevision > (summary.summaryRevision ?? 0) else { return summary }
                return applying(update, to: summary)
            }
            locallyCreatedUnindexedSessionIDs.subtract(all.map(\.id))
            reconcileSelection()
            saveCache()
            return true
        } catch {
            guard sessionCatalogLoadOwner.admits(loadGeneration) else { return false }
            if surfacingErrors { surface(error) }
            return false
        }
    }

    func refreshDevices() async {
        struct Response: Decodable { let devices: [PairedDevice] }
        deviceLoadGeneration &+= 1
        let generation = deviceLoadGeneration
        do {
            let response: Response = try await client.request("device.list", EmptyParams())
            guard deviceLoadGeneration == generation else { return }
            pairedDevices = response.devices
        } catch {
            guard deviceLoadGeneration == generation else { return }
            surface(error)
        }
    }

    func revokeDevice(_ id: String) async throws {
        struct Params: Codable { let deviceId: String; let commandId: String }
        struct Response: Codable { let revoked: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(deviceId: id, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "device.revoke", commandId: commandID) {
            try await client.request("device.revoke", params)
        }
        if response.revoked {
            pairedDevices.removeAll { $0.id == id }
            if let profile = profiles.selected, profile.deviceId == id {
                let generation = await beginConnectionTransition()
                guard lifecyclePhase.generation == generation else { return }
                profiles.remove(profile)
                finishConnectionTransition(generation)
                connectionState = .unpaired
                hasResolvedLaunchState = true
            }
        }
    }

    func inspectLegacyImport() async {
        struct Response: Decodable { let available: Bool; let importedCount: Int }
        legacyImportLoadGeneration &+= 1
        let generation = legacyImportLoadGeneration
        do {
            let response: Response = try await client.request("legacy.inspect", EmptyParams())
            guard legacyImportLoadGeneration == generation else { return }
            legacyImportAvailable = response.available
            legacyImportedCount = response.importedCount
        } catch {
            guard legacyImportLoadGeneration == generation else { return }
            surface(error)
        }
    }

    func importLegacySessions(port: Int = 9849) async throws {
        struct Params: Codable { let port: Int; let commandId: String }
        struct Response: Codable { let imported: Int; let skipped: Int }
        let commandID = uuidSource.next().uuidString
        let params = Params(port: port, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "legacy.import", commandId: commandID) {
            try await client.request("legacy.import", params, timeout: .seconds(600))
        }
        legacyImportedCount += response.imported
        postNotice("Imported \(response.imported) legacy session\(response.imported == 1 ? "" : "s"); skipped \(response.skipped).")
        await refreshSessions()
    }

    func importSession(from url: URL, cwd: String) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let uploadID = try await client.upload(name: url.lastPathComponent, mimeType: "application/x-ndjson", data: data)
        struct Params: Codable { let uploadId, cwd, commandId: String }
        typealias Response = SessionMutationResponse
        let commandID = uuidSource.next().uuidString
        let params = Params(uploadId: uploadID, cwd: cwd, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.import", commandId: commandID) {
            try await client.request("session.import", params, timeout: .seconds(120))
        }
        await refreshSessions()
        return response.sessionId
    }

    func createSession(cwd: String) async throws -> String {
        struct Params: Codable { let cwd: String; let commandId: String }
        typealias Response = SessionMutationResponse
        let commandID = uuidSource.next().uuidString
        let params = Params(cwd: cwd, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.create", commandId: commandID) {
            try await client.request("session.create", params, timeout: .seconds(60))
        }
        locallyCreatedUnindexedSessionIDs.insert(response.sessionId)
        defaultWorkspace = cwd
        UserDefaults.standard.set(cwd, forKey: "defaultWorkspace.v1")
        await refreshSessions()
        return response.sessionId
    }

    /// Starts a new mounted chat presentation. Unlike reconnect synchronization,
    /// this always installs a fresh authoritative bounded tail and never carries
    /// an explicitly paged prefix across navigation lifetimes.
    func openSessionPresentation(_ id: String) async throws -> Int {
        try await measure(.sessionOpen) {
            (try await performSessionPresentationOpen(id), .none)
        }
    }

    private func performSessionPresentationOpen(_ id: String) async throws -> Int {
        presentationOpenGeneration &+= 1
        let generation = presentationOpenGeneration
        if subscribedSessionID != id { await closeCurrentSubscription() }
        guard generation == presentationOpenGeneration else { throw CancellationError() }
        selectedSessionID = id
        authoritativeSessionIDs.remove(id)
        let synchronized = await synchronizeSession(
            id,
            replacingVisibleTranscript: true,
            presentationGeneration: generation
        )
        guard generation == presentationOpenGeneration,
              selectedSessionID == id,
              synchronized,
              subscribedSessionID == id else {
            throw GatewayFailure(code: "sync_failed", message: "Tron could not synchronize this session.", retryable: true, details: nil)
        }
        authoritativeSessionIDs.insert(id)
        let target = SessionPresentationTarget(sessionID: id, generation: generation)
        revokedPresentationTargets.remove(target)
        mountedPresentationGenerationBySession[id] = generation
        Task { [weak self] in
            guard let self else { return }
            async let providerRefresh: Bool = self.refreshProviders(target: .session(id: id))
            async let commandRefresh: Void = self.loadCommands(for: id)
            _ = await (providerRefresh, commandRefresh)
        }
        return generation
    }

    func closeSessionPresentation(_ id: String, generation: Int) async {
        let target = SessionPresentationTarget(sessionID: id, generation: generation)
        revokedPresentationTargets.remove(target)
        pendingAttachmentsByTarget.removeValue(for: target)
        editorRequestByTarget.removeValue(for: target)
        guard Self.ownsPresentation(
            mountedGeneration: mountedPresentationGenerationBySession[id],
            requestedGeneration: generation
        ) else { return }
        mountedPresentationGenerationBySession[id] = nil
        authoritativeSessionIDs.remove(id)
        if selectedSessionID == id { selectedSessionID = nil }
        await closeSubscription(id, expectedPresentationGeneration: generation)
    }

    func loadEarlierTranscript(sessionID: String, presentationGeneration: Int) async {
        guard !loadingEarlierTranscript,
              let current = snapshots[sessionID],
              let before = current.transcriptStart,
              before > 0 else { return }
        let request = ChatTranscriptPageRequest(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration,
            runtimeGeneration: current.runtimeGeneration,
            before: before,
            expectedNextEntryID: current.transcript.first?.id
        )
        struct Params: Codable { let sessionId: String; let before: Int; let expectedNextEntryId: String? }
        struct Response: Decodable { let items: [TranscriptItem]; let start: Int; let total: Int }
        loadingEarlierTranscript = true
        defer { loadingEarlierTranscript = false }
        do {
            let response: Response = try await client.request(
                "session.transcript",
                Params(sessionId: sessionID, before: before, expectedNextEntryId: current.transcript.first?.id),
                timeout: .seconds(60)
            )
            guard !Task.isCancelled,
                  var snapshot = snapshots[sessionID],
                  request.canInstall(
                    sessionID: sessionID,
                    presentationGeneration: mountedPresentationGenerationBySession[sessionID] ?? -1,
                    runtimeGeneration: snapshot.runtimeGeneration,
                    transcriptStart: snapshot.transcriptStart,
                    firstTranscriptID: snapshot.transcript.first?.id
                  ) else { return }
            let existingIDs = Set(snapshot.transcript.map(\.id))
            snapshot.transcript = response.items.filter { !existingIDs.contains($0.id) } + snapshot.transcript
            snapshot.transcriptStart = response.start
            snapshot.transcriptTotal = response.total
            snapshots[sessionID] = snapshot
            saveCache()
        } catch is CancellationError {
            return
        } catch { surface(error) }
    }

    private func invalidateSessionConnectionOwnership() {
        subscribedSessionID = nil
        subscriptionTokenBySession.removeAll()
        sessionSynchronization.reset()
    }

    private func closeCurrentSubscription() async {
        guard let sessionID = subscribedSessionID else { return }
        await closeSubscription(sessionID)
    }

    private func closeSubscription(_ sessionID: String, expectedPresentationGeneration: Int? = nil) async {
        if let expectedPresentationGeneration,
           mountedPresentationGenerationBySession[sessionID] != nil,
           mountedPresentationGenerationBySession[sessionID] != expectedPresentationGeneration { return }
        guard let subscriptionToken = subscriptionTokenBySession[sessionID] else { return }
        struct Params: Codable { let sessionId, subscriptionToken: String }
        struct Response: Decodable { let closed: Bool }
        let response: Response? = try? await client.request(
            "session.close",
            Params(sessionId: sessionID, subscriptionToken: subscriptionToken)
        )
        guard Self.shouldClearSubscription(
            installedToken: subscriptionTokenBySession[sessionID],
            closingToken: subscriptionToken,
            gatewayClosed: response?.closed == true
        ) else { return }
        subscriptionTokenBySession[sessionID] = nil
        if subscribedSessionID == sessionID { subscribedSessionID = nil }
    }

    private func closeProvisionalSubscription(_ sessionID: String, token: String) async {
        struct Params: Codable { let sessionId, subscriptionToken: String }
        struct Response: Decodable { let closed: Bool }
        let _: Response? = try? await client.request(
            "session.close",
            Params(sessionId: sessionID, subscriptionToken: token)
        )
    }

    private func discardSubscription(_ sessionID: String, token: String) async {
        await closeProvisionalSubscription(sessionID, token: token)
        guard subscriptionTokenBySession[sessionID] == token else { return }
        subscriptionTokenBySession[sessionID] = nil
        if subscribedSessionID == sessionID { subscribedSessionID = nil }
    }

    static func ownsPresentation(
        mountedGeneration: Int?,
        requestedGeneration: Int
    ) -> Bool {
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

    func send(_ text: String, sessionID: String, behavior: String? = nil) async throws {
        try await send(text, sessionID: sessionID, uploadIDs: [], behavior: behavior)
    }

    func sendSharedContent(
        _ text: String,
        target: SessionPresentationTarget
    ) async throws {
        guard ownsPresentation(target) else { throw CancellationError() }
        try await send(text, sessionID: target.sessionID, uploadIDs: [], behavior: nil)
    }

    func send(
        _ text: String,
        target: SessionPresentationTarget,
        behavior: String? = nil
    ) async throws {
        guard ownsPresentation(target) else { throw CancellationError() }
        let sentIDs = pendingAttachments(for: target).map(\.id)
        try await send(text, sessionID: target.sessionID, uploadIDs: sentIDs, behavior: behavior)
        guard var attachments = pendingAttachmentsByTarget[target] else { return }
        attachments.removeAll { sentIDs.contains($0.id) }
        pendingAttachmentsByTarget[target] = attachments.isEmpty ? nil : attachments
    }

    private func send(
        _ text: String,
        sessionID: String,
        uploadIDs: [String],
        behavior: String?
    ) async throws {
        struct Params: Codable {
            let sessionId: String
            let text: String
            let uploadIds: [String]
            let behavior: String?
            let commandId: String
        }
        struct Response: Codable { let operationId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            sessionId: sessionID,
            text: text,
            uploadIds: uploadIDs,
            behavior: behavior,
            commandId: commandID
        )
        let _: Response = try await confirmedMutation(method: "session.prompt", commandId: commandID) {
            try await client.request("session.prompt", params, as: Response.self, timeout: .seconds(15))
        }
    }

    func abort(sessionID: String, kind: String = "agent") async {
        struct Params: Codable { let sessionId, kind, commandId: String }
        struct Response: Codable { let aborted: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, kind: kind, commandId: commandID)
        do {
            let _: Response = try await confirmedMutation(method: "session.abort", commandId: commandID) {
                try await client.request("session.abort", params, timeout: .seconds(30))
            }
        } catch { surface(error) }
    }

    func clearQueue(sessionID: String) async throws -> SessionSnapshot.QueuedMessages {
        struct Params: Codable { let sessionId, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, commandId: commandID)
        let cleared: SessionSnapshot.QueuedMessages = try await confirmedMutation(method: "session.clearQueue", commandId: commandID) {
            try await client.request("session.clearQueue", params)
        }
        if var snapshot = snapshots[sessionID] {
            snapshot.queued = .init(steering: [], followUp: [])
            snapshots[sessionID] = snapshot
        }
        return cleared
    }

    func executeBash(_ command: String, sessionID: String, excludeFromContext: Bool = false) async throws {
        struct Params: Codable { let sessionId, command: String; let excludeFromContext: Bool; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, command: command, excludeFromContext: excludeFromContext, commandId: commandID)
        _ = try await confirmedMutationValue(method: "session.bash", commandId: commandID) {
            try await client.requestValue("session.bash", params, timeout: .seconds(300))
        }
    }

    func setModel(_ model: ModelRef, sessionID: String) async throws {
        struct Params: Codable { let sessionId, provider, modelId, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, provider: model.provider, modelId: model.id, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.setModel", commandId: commandID) {
            try await client.request("session.setModel", params)
        }
    }

    func setThinking(_ level: String, sessionID: String) async throws {
        struct Params: Codable { let sessionId, level, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, level: level, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.setThinking", commandId: commandID) {
            try await client.request("session.setThinking", params)
        }
    }

    func renameSession(_ sessionID: String, name: String) async throws {
        struct Params: Codable { let sessionId, name, commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, name: name, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.rename", commandId: commandID) {
            try await client.request("session.rename", params)
        }
    }

    func compact(sessionID: String, instructions: String? = nil) async throws {
        struct Params: Codable { let sessionId: String; let instructions: String?; let commandId: String }
        struct Response: Codable { let compacted: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, instructions: instructions, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "session.compact", commandId: commandID) {
            try await client.request("session.compact", params, timeout: .seconds(300))
        }
    }

    func setTools(_ tools: [String], sessionID: String) async throws {
        struct Params: Codable { let sessionId: String; let tools: [String]; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, tools: tools, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.setTools", commandId: commandID) {
            try await client.request("session.setTools", params)
        }
    }

    func fork(
        sessionID: String,
        entryID: String,
        position: String = "before"
    ) async throws -> SessionNavigationRoute {
        struct Params: Codable { let sessionId, entryId, position, commandId: String }
        struct Response: Codable { let sessionId: String; let selectedText: String? }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, position: position, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.fork", commandId: commandID) {
            try await client.request("session.fork", params, timeout: .seconds(120))
        }
        locallyCreatedUnindexedSessionIDs.insert(response.sessionId)
        await refreshSessions()
        return SessionNavigationRoute(sessionID: response.sessionId, editorText: response.selectedText)
    }

    @discardableResult
    func navigate(
        sessionID: String,
        entryID: String,
        summarize: Bool,
        instructions: String? = nil,
        replaceInstructions: Bool = false,
        label: String? = nil
    ) async throws -> String? {
        let editorTarget = presentationTarget(for: sessionID)
        struct Params: Codable {
            let sessionId, entryId: String
            let summarize: Bool
            let instructions: String?
            let replaceInstructions: Bool
            let label: String?
            let commandId: String
        }
        struct Response: Codable { let editorText: String? }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, summarize: summarize, instructions: instructions, replaceInstructions: replaceInstructions, label: label, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.navigate", commandId: commandID) {
            try await client.request("session.navigate", params, timeout: .seconds(300))
        }
        if let editorText = response.editorText,
           let editorTarget,
           ownsPresentation(editorTarget) {
            editorRequestByTarget[editorTarget] = .init(
                sessionId: sessionID,
                presentationGeneration: editorTarget.generation,
                revision: Int(Date.now.timeIntervalSince1970 * 1_000),
                action: .set,
                text: editorText,
                fullText: editorText
            )
        }
        await loadTree(sessionID: sessionID)
        return response.editorText
    }

    func setLabel(sessionID: String, entryID: String, label: String?) async throws {
        struct Params: Codable { let sessionId, entryId: String; let label: String?; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, label: label, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.label", commandId: commandID) {
            try await client.request("session.label", params)
        }
        await loadTree(sessionID: sessionID)
    }

    func exportSession(sessionID: String, format: String) async throws -> URL {
        guard subscribedSessionID == sessionID else {
            throw GatewayFailure(code: "sync_failed", message: "Open the session before exporting it.", retryable: true, details: nil)
        }
        struct Params: Codable { let sessionId, format: String }
        struct Response: Decodable { let blobId, name, mimeType: String }
        let response: Response = try await client.request("session.export", Params(sessionId: sessionID, format: format), timeout: .seconds(120))
        let data = try await client.blob(id: response.blobId).0
        let directory = FileManager.default.temporaryDirectory.appending(path: "TronExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: response.name, directoryHint: .notDirectory)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func deleteSession(_ id: String) async throws {
        struct Params: Codable { let sessionId, commandId: String }
        struct Response: Codable { let deleted: Bool }
        if subscribedSessionID == id { await closeCurrentSubscription() }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: id, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "session.delete", commandId: commandID) {
            try await client.request("session.delete", params, timeout: .seconds(60))
        }
        snapshots.removeValue(forKey: id)
        liveSessionSummaryUpdates.removeValue(forKey: id)
        sessionStructureRevisions.removeValue(forKey: id)
        sessionContextRevisions.removeValue(forKey: id)
        sessionResourceRevisions.removeValue(forKey: id)
        locallyCreatedUnindexedSessionIDs.remove(id)
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = nil }
        saveCache()
    }

    func loadContext(sessionID: String) async {
        guard subscribedSessionID == sessionID,
              let subscriptionToken = subscriptionTokenBySession[sessionID] else { return }
        struct Params: Codable { let sessionId: String }
        do {
            let loaded = try await client.requestValue("session.context", Params(sessionId: sessionID), timeout: .seconds(60))
            guard Self.ownsSubscription(
                sessionID: sessionID,
                subscribedSessionID: subscribedSessionID,
                installedToken: subscriptionTokenBySession[sessionID],
                requestedToken: subscriptionToken
            ) else { return }
            context = loaded
        } catch { surface(error) }
    }

    func loadTree(sessionID: String) async {
        guard subscribedSessionID == sessionID,
              let subscriptionToken = subscriptionTokenBySession[sessionID] else { return }
        struct Params: Codable { let sessionId: String }
        do {
            let loaded: [SessionTreeNode] = try await client.request("session.tree", Params(sessionId: sessionID))
            guard Self.ownsSubscription(
                sessionID: sessionID,
                subscribedSessionID: subscribedSessionID,
                installedToken: subscriptionTokenBySession[sessionID],
                requestedToken: subscriptionToken
            ) else { return }
            sessionTree = loaded
        } catch { surface(error) }
    }

    func loadCommands(sessionID: String) async {
        await loadCommands(for: sessionID)
    }

    private func loadCommands(for sessionID: String) async {
        guard subscribedSessionID == sessionID,
              let subscriptionToken = subscriptionTokenBySession[sessionID] else { return }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let commands: [CommandInfo] }
        do {
            let response: Response = try await client.request("session.commands", Params(sessionId: sessionID))
            guard Self.ownsSubscription(
                sessionID: sessionID,
                subscribedSessionID: subscribedSessionID,
                installedToken: subscriptionTokenBySession[sessionID],
                requestedToken: subscriptionToken
            ) else { return }
            commands = response.commands
        } catch { surface(error) }
    }

    func loadResources(sessionID: String) async {
        guard subscribedSessionID == sessionID,
              let subscriptionToken = subscriptionTokenBySession[sessionID] else { return }
        struct Params: Codable { let sessionId: String }
        do {
            let loaded = try await client.requestValue("session.resources", Params(sessionId: sessionID), timeout: .seconds(60))
            guard Self.ownsSubscription(
                sessionID: sessionID,
                subscribedSessionID: subscribedSessionID,
                installedToken: subscriptionTokenBySession[sessionID],
                requestedToken: subscriptionToken
            ) else { return }
            resources = loaded
        } catch { surface(error) }
    }

    func reloadResources(sessionID: String) async throws {
        struct Params: Codable { let sessionId, commandId: String }
        struct Response: Codable { let reloaded: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "session.reloadResources", commandId: commandID) {
            try await client.request("session.reloadResources", params, timeout: .seconds(120))
        }
    }

    func archive(_ id: String) {
        // Kept only for migration of previous local-hidden state. New UI uses
        // canonical session deletion and labels it accurately.
        hiddenSessionIDs.insert(id)
        persistHidden()
        if selectedSessionID == id { selectedSessionID = nil }
    }

    func upload(
        name: String,
        mimeType: String,
        data: Data,
        target: SessionPresentationTarget
    ) async throws {
        guard ownsPresentation(target) else { throw CancellationError() }
        let id = try await client.upload(name: name, mimeType: mimeType, data: data)
        guard ownsPresentation(target) else { return }
        var attachments = pendingAttachmentsByTarget[target] ?? []
        attachments.append(PendingAttachment(
            id: id,
            name: name,
            mimeType: mimeType,
            size: data.count,
            previewData: mimeType.hasPrefix("image/") ? data : nil
        ))
        pendingAttachmentsByTarget[target] = attachments
    }

    func removeAttachment(_ id: String, target: SessionPresentationTarget) {
        guard var attachments = pendingAttachmentsByTarget[target] else { return }
        attachments.removeAll { $0.id == id }
        pendingAttachmentsByTarget[target] = attachments.isEmpty ? nil : attachments
    }

    @discardableResult
    func refreshProviders(target: ProviderCatalogTarget) async -> Bool {
        struct ProviderParams: Codable { let sessionId: String? }
        struct ModelParams: Codable { let sessionId: String?; let cursor: String?; let limit: Int }
        struct ProviderResponse: Decodable { let providers: [ProviderSummary] }
        struct ModelResponse: Decodable { let models: [ModelSummary]; let nextCursor: String? }
        let generation = (providerLoadGenerationByTarget[target] ?? 0) + 1
        providerLoadGenerationByTarget[target] = generation
        do {
            async let providerRequest: ProviderResponse = client.request("provider.list", ProviderParams(sessionId: target.sessionID))
            var models: [ModelSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let response: ModelResponse = try await client.request(
                    "model.list",
                    ModelParams(sessionId: target.sessionID, cursor: cursor, limit: 500)
                )
                models.append(contentsOf: response.models)
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
            guard providerLoadGenerationByTarget[target] == generation else { return false }
            providerCatalogByTarget[target] = ProviderCatalog(providers: providers, models: models)
            return true
        } catch {
            guard providerLoadGenerationByTarget[target] == generation else { return false }
            surface(error)
            return false
        }
    }

    func beginAuth(providerID: String, authType: String, target: ProviderCatalogTarget) async throws {
        struct Params: Codable { let providerId, authType: String; let sessionId: String? }
        struct Response: Decodable { let operationId: String }
        let response: Response = try await client.request("auth.begin", Params(providerId: providerID, authType: authType, sessionId: target.sessionID), timeout: .seconds(15))
        providerCatalogTargetByAuthOperation[response.operationId] = target
        authEvent = .init(
            operationId: response.operationId,
            kind: .progress,
            message: "Starting provider login…",
            links: [],
            url: nil,
            instructions: nil,
            userCode: nil,
            verificationURL: nil,
            intervalSeconds: nil,
            expiresInSeconds: nil
        )
    }

    func answerAuth(_ value: String) async throws {
        guard let prompt = authPrompt else { return }
        struct Params: Codable { let operationId, promptId, value: String }
        struct Response: Decodable { let answered: Bool }
        let _: Response = try await client.request("auth.respond", Params(operationId: prompt.operationId, promptId: prompt.id, value: value))
        // A provider may publish its next prompt before this response resumes.
        // Never erase newer canonical auth state with a stale completion.
        if authPrompt?.operationId == prompt.operationId, authPrompt?.id == prompt.id {
            authPrompt = nil
        }
    }

    func cancelAuth(operationID: String? = nil) async {
        guard let id = operationID ?? authPrompt?.operationId ?? authEvent?.operationId else { return }
        struct Params: Codable { let operationId: String }
        struct Response: Decodable { let cancelled: Bool }
        let response: Response? = try? await client.request("auth.cancel", Params(operationId: id))
        if authPrompt?.operationId == id { authPrompt = nil }
        if authEvent?.operationId == id { authEvent = nil }
        if response?.cancelled == true {
            providerCatalogTargetByAuthOperation[id] = nil
        }
    }

    func refreshModelCatalog(target: ProviderCatalogTarget, force: Bool = true) async throws {
        struct Params: Codable { let force: Bool; let sessionId: String?; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(force: force, sessionId: target.sessionID, commandId: commandID)
        _ = try await confirmedMutationValue(method: "models.refresh", commandId: commandID) {
            try await client.requestValue("models.refresh", params, timeout: .seconds(75))
        }
        await refreshProviders(target: target)
    }

    func logout(providerID: String, target: ProviderCatalogTarget) async throws {
        struct Params: Codable { let providerId, commandId: String; let sessionId: String? }
        struct Response: Codable { let loggedOut: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(providerId: providerID, commandId: commandID, sessionId: target.sessionID)
        let _: Response = try await confirmedMutation(method: "auth.logout", commandId: commandID) {
            try await client.request("auth.logout", params, timeout: .seconds(60))
        }
        await refreshProviders(target: target)
    }

    @discardableResult
    func refreshSettings(target: SettingsTarget) async -> Bool {
        struct Params: Codable { let cwd: String?; let scope: String }
        let generation = (settingsLoadGenerationByTarget[target] ?? 0) + 1
        settingsLoadGenerationByTarget[target] = generation
        do {
            let value = try await client.requestValue(
                "settings.get",
                Params(cwd: target.cwd, scope: target.scope.rawValue)
            )
            guard settingsLoadGenerationByTarget[target] == generation else { return false }
            settingsByTarget[target] = value
            return true
        } catch {
            guard settingsLoadGenerationByTarget[target] == generation else { return false }
            surface(error)
            return false
        }
    }

    func updateSettings(_ patch: JSONValue, target: SettingsTarget) async throws {
        struct Params: Codable { let patch: JSONValue; let scope: String; let cwd: String?; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(patch: patch, scope: target.scope.rawValue, cwd: target.cwd, commandId: commandID)
        let _: JSONValue = try await confirmedMutationValue(method: "settings.update", commandId: commandID) {
            try await client.requestValue("settings.update", params, timeout: .seconds(60))
        }
        _ = await refreshSettings(target: target)
    }

    func inspectTrust(target: TrustTarget) async throws -> JSONValue {
        struct Params: Codable { let cwd: String }
        return try await client.requestValue("trust.inspect", Params(cwd: target.cwd))
    }

    func setTrust(target: TrustTarget, decision: Bool?) async throws -> JSONValue {
        struct Params: Codable { let cwd: String; let decision: Bool?; let commandId: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(cwd: target.cwd, decision: decision, commandId: commandID)
        return try await confirmedMutationValue(method: "trust.set", commandId: commandID) {
            try await client.requestValue("trust.set", params)
        }
    }

    @discardableResult
    func loadPackages(target: PackageConfigurationTarget) async -> Bool {
        struct Params: Codable { let cwd: String? }
        let generation = (packageLoadGenerationByTarget[target] ?? 0) + 1
        packageLoadGenerationByTarget[target] = generation
        do {
            let inventory: PackageInventory = try await client.request(
                "packages.list",
                Params(cwd: target.cwd),
                timeout: .seconds(120)
            )
            guard packageLoadGenerationByTarget[target] == generation else { return false }
            packageInventoryByTarget[target] = inventory
            return true
        } catch {
            guard packageLoadGenerationByTarget[target] == generation else { return false }
            surface(error)
            return false
        }
    }

    @discardableResult
    func checkPackageUpdates(target: PackageConfigurationTarget) async -> Bool {
        struct Params: Codable { let cwd: String? }
        struct Response: Decodable { let updates: [PackageUpdate] }
        let generation = (packageUpdateGenerationByTarget[target] ?? 0) + 1
        packageUpdateGenerationByTarget[target] = generation
        do {
            let response: Response = try await client.request(
                "packages.checkUpdates",
                Params(cwd: target.cwd),
                timeout: .seconds(180)
            )
            guard packageUpdateGenerationByTarget[target] == generation else { return false }
            packageUpdatesByTarget[target] = response.updates
            return true
        } catch {
            guard packageUpdateGenerationByTarget[target] == generation else { return false }
            surface(error)
            return false
        }
    }

    func mutatePackage(
        action: String,
        source: String?,
        local: Bool,
        target: PackageConfigurationTarget
    ) async throws {
        struct Params: Codable { let source: String?; let local: Bool; let cwd: String?; let commandId: String }
        let method = "packages.\(action)"
        let commandID = uuidSource.next().uuidString
        let params = Params(source: source, local: local, cwd: target.cwd, commandId: commandID)
        _ = try await confirmedMutationValue(method: method, commandId: commandID) {
            try await client.requestValue(method, params, timeout: .seconds(300))
        }
        if action == "update", source == nil {
            packageUpdatesByTarget[target] = []
        } else if action == "update" || action == "remove", let source {
            packageUpdatesByTarget[target]?.removeAll { $0.source == source }
        }
        _ = await loadPackages(target: target)
    }

    @discardableResult
    func loadCustomModels(target: CustomModelTarget) async -> Bool {
        let generation = (customModelLoadGenerationByTarget[target] ?? 0) + 1
        customModelLoadGenerationByTarget[target] = generation
        do {
            let value = try await client.requestValue("models.custom.get", EmptyParams())
            guard customModelLoadGenerationByTarget[target] == generation else { return false }
            customModelsByTarget[target] = value
            return true
        } catch {
            guard customModelLoadGenerationByTarget[target] == generation else { return false }
            surface(error)
            return false
        }
    }

    func replaceCustomModels(_ document: JSONValue, target: CustomModelTarget) async throws {
        let client = self.client
        let uuidSource = self.uuidSource
        try await CustomModelDocumentWriter(request: { method, params in
            try await client.requestValue(method, params)
        }, put: { [weak self] method, params in
            guard let self,
                  let commandID = params.objectValue?["commandId"]?.stringValue else {
                throw GatewayFailure(code: "invalid_request", message: "Custom model command ID is missing.", retryable: false, details: nil)
            }
            return try await self.confirmedMutationValue(method: method, commandId: commandID) {
                try await client.requestValue(method, params)
            }
        }, makeCommandID: {
            uuidSource.next().uuidString
        }).replace(document)
    }

    nonisolated static func supportsSafeGatewayRestart(capabilities: [String]) -> Bool {
        capabilities.contains("restart-drain.v1")
    }

    func restartGateway() async throws {
        guard Self.supportsSafeGatewayRestart(capabilities: gatewayInfo?.capabilities ?? []) else {
            throw GatewayFailure(
                code: "unsupported",
                message: "Update the Mac Gateway before restarting it from iPhone; this version cannot preserve accepted runs during restart.",
                retryable: false,
                details: nil
            )
        }
        struct Params: Codable { let commandId: String }
        struct Response: Codable { let restarting: Bool; let scheduled: Bool; let activeSessionIds: [String] }
        let commandID = uuidSource.next().uuidString
        let response: Response = try await confirmedMutation(method: "gateway.restart", commandId: commandID) {
            try await client.request("gateway.restart", Params(commandId: commandID))
        }
        if response.scheduled {
            postNotice(
                "Gateway restart scheduled after \(response.activeSessionIds.count) active agent run\(response.activeSessionIds.count == 1 ? "" : "s") finishes.",
                replacing: .gatewayRestart
            )
        } else {
            postNotice("Gateway is restarting. Tron will reconnect automatically.", replacing: .gatewayRestart)
        }
    }

    func loadWorkspace(path: String? = nil) async throws {
        struct Params: Codable { let path: String? }
        workspaceLoadGeneration &+= 1
        let generation = workspaceLoadGeneration
        let loaded: WorkspaceListing = try await client.request("filesystem.list", Params(path: path), timeout: .seconds(30))
        guard workspaceLoadGeneration == generation else { return }
        workspace = loaded
    }

    func createFolder(parent: String, name: String) async throws {
        struct Params: Codable { let parent, name, commandId: String }
        struct Response: Codable { let path: String }
        let commandID = uuidSource.next().uuidString
        let params = Params(parent: parent, name: name, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "filesystem.mkdir", commandId: commandID) {
            try await client.request("filesystem.mkdir", params)
        }
        try await loadWorkspace(path: parent)
        defaultWorkspace = response.path
    }

    func answerInteraction(
        _ interaction: ExtensionInteraction,
        sessionID: String,
        value: JSONValue?,
        cancelled: Bool
    ) async throws {
        struct Params: Codable { let sessionId, interactionId: String; let value: JSONValue?; let cancelled: Bool; let commandId: String }
        struct Response: Codable { let answered: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(sessionId: sessionID, interactionId: interaction.id, value: value, cancelled: cancelled, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "extension.respond", commandId: commandID) {
            try await client.request("extension.respond", params)
        }
    }

    func beginTerminalPresentation(sessionID: String) -> TerminalPresentationTarget {
        terminalState.beginPresentation(sessionID: sessionID)
    }

    func beginTerminalIntent(
        for target: TerminalPresentationTarget
    ) -> TerminalPresentationIntent? {
        guard let transition = terminalState.beginIntent(for: target) else { return nil }
        scheduleTerminalDetaches(transition.detached)
        return transition.intent
    }

    func closeTerminalPresentation(_ target: TerminalPresentationTarget) {
        scheduleTerminalDetaches(terminalState.revokePresentation(target))
    }

    func ownsTerminalIntent(_ intent: TerminalPresentationIntent) -> Bool {
        terminalState.owns(intent)
    }

    func terminalReplay(for terminalID: String) -> TerminalReplayProjection {
        terminalState.replay(for: terminalID)
    }

    func terminalHasExited(_ terminalID: String) -> Bool {
        terminalState.hasExited(terminalID)
    }

    func listTerminals(intent: TerminalPresentationIntent) async throws -> [TerminalSummary] {
        let sessionID = intent.presentation.sessionID
        let lifecycleGeneration = lifecyclePhase.generation
        let connectionID = gatewayConnectionID
        let subscriptionToken = subscriptionTokenBySession[sessionID]
        guard terminalState.owns(intent),
              subscribedSessionID == sessionID,
              subscriptionToken != nil else {
            throw GatewayFailure(code: "sync_failed", message: "Open the session before listing terminals.", retryable: true, details: nil)
        }
        struct Params: Codable, Sendable { let sessionId: String }
        struct Response: Decodable, Sendable { let terminals: [TerminalSummary] }
        let request = Task { try await client.request("terminal.list", Params(sessionId: sessionID)) as Response }
        let response = try await request.value
        try requireLifecycle(lifecycleGeneration)
        try requireConnection(connectionID)
        guard terminalState.owns(intent),
              subscribedSessionID == sessionID,
              subscriptionTokenBySession[sessionID] == subscriptionToken,
              response.terminals.allSatisfy({ $0.sessionId == sessionID }) else { throw CancellationError() }
        terminalState.installInventory(response.terminals, sessionID: sessionID)
        return response.terminals
    }

    func openTerminal(
        intent: TerminalPresentationIntent,
        columns: Int,
        rows: Int
    ) async throws -> TerminalSummary {
        let lifecycleGeneration = lifecyclePhase.generation
        guard let connectionID = gatewayConnectionID,
              let lease = terminalState.beginOpen(intent: intent, connectionID: connectionID) else {
            throw CancellationError()
        }
        return try await measure(.terminalAttachReplay) {
            struct Params: Codable, Sendable { let sessionId: String; let columns, rows: Int; let commandId: String }
            struct Replay: Codable, Sendable { let terminal: TerminalSummary; let chunks: [TerminalChunk]; let reset: Bool }
            struct Response: Codable, Sendable { let terminal: TerminalSummary; let replay: Replay }
            let commandID = uuidSource.next().uuidString
            let params = Params(
                sessionId: intent.presentation.sessionID,
                columns: columns,
                rows: rows,
                commandId: commandID
            )
            let request = Task {
                try await confirmedMutation(method: "terminal.open", commandId: commandID) {
                    try await client.request("terminal.open", params)
                } as Response
            }
            let response: Response
            do {
                response = try await request.value
            } catch {
                terminalState.finish(lease)
                throw error
            }
            guard !Task.isCancelled,
                  admitsLifecycle(lifecycleGeneration),
                  gatewayConnectionID == connectionID,
                  let installation = terminalState.installReplay(
                    response.replay.chunks,
                    terminal: response.terminal,
                    reset: true,
                    after: 0,
                    lease: lease
                  ) else {
                terminalState.finish(lease)
                scheduleTerminalDetachIfUnowned(TerminalDetachClaim(
                    terminalID: response.terminal.id,
                    connectionID: connectionID
                ))
                throw CancellationError()
            }
            if installation.requiresReconciliation { reconcileTerminal(response.terminal.id) }
            return (
                response.terminal,
                PerformanceMetrics(itemCount: installation.admittedCount)
            )
        }
    }

    func attachTerminal(
        _ id: String,
        after: Int,
        intent: TerminalPresentationIntent
    ) async throws -> TerminalSummary {
        guard let connectionID = gatewayConnectionID,
              let lease = terminalState.beginAttachment(
                terminalID: id,
                intent: intent,
                connectionID: connectionID
              ) else { throw CancellationError() }
        return try await performTerminalAttach(
            id,
            after: after,
            lease: lease,
            lifecycleGeneration: lifecyclePhase.generation
        )
    }

    private func performTerminalAttach(
        _ id: String,
        after: Int,
        lease: TerminalAttachmentLease,
        lifecycleGeneration: Int
    ) async throws -> TerminalSummary {
        try await measure(.terminalAttachReplay) {
            struct Params: Codable, Sendable { let terminalId: String; let afterSequence: Int }
            struct Response: Decodable, Sendable { let terminal: TerminalSummary; let chunks: [TerminalChunk]; let reset: Bool }
            let request = Task {
                try await client.request(
                    "terminal.attach",
                    Params(terminalId: id, afterSequence: after)
                ) as Response
            }
            let response: Response
            do {
                response = try await request.value
            } catch {
                terminalState.finish(lease)
                scheduleTerminalDetachIfUnowned(TerminalDetachClaim(
                    terminalID: id,
                    connectionID: lease.connectionID
                ))
                throw error
            }
            guard !Task.isCancelled,
                  admitsLifecycle(lifecycleGeneration),
                  gatewayConnectionID == lease.connectionID,
                  let installation = terminalState.installReplay(
                    response.chunks,
                    terminal: response.terminal,
                    reset: response.reset,
                    after: after,
                    lease: lease
                  ) else {
                terminalState.finish(lease)
                scheduleTerminalDetachIfUnowned(TerminalDetachClaim(
                    terminalID: id,
                    connectionID: lease.connectionID
                ))
                if terminalState.requiresReconciliation(id) { reconcileTerminal(id) }
                throw CancellationError()
            }
            if installation.requiresReconciliation { reconcileTerminal(response.terminal.id) }
            return (
                response.terminal,
                PerformanceMetrics(itemCount: installation.admittedCount)
            )
        }
    }

    private func scheduleTerminalDetaches(_ claims: [TerminalDetachClaim]) {
        for claim in claims { scheduleTerminalDetachIfUnowned(claim) }
    }

    private func scheduleTerminalDetachIfUnowned(_ claim: TerminalDetachClaim) {
        let lifecycleGeneration = lifecyclePhase.generation
        terminalCleanupGeneration &+= 1
        let cleanupGeneration = terminalCleanupGeneration
        terminalCleanupTasks[cleanupGeneration] = Task { [weak self] in
            guard let self else { return }
            defer { self.terminalCleanupTasks.removeValue(forKey: cleanupGeneration) }
            guard self.admitsLifecycle(lifecycleGeneration),
                  self.gatewayConnectionID == claim.connectionID,
                  !self.terminalState.hasCurrentInterest(
                    in: claim.terminalID,
                    connectionID: claim.connectionID
                  ) else { return }
            struct Params: Codable, Sendable { let terminalId: String }
            struct Response: Decodable, Sendable { let detached: Bool }
            let _: Response? = try? await self.client.request(
                "terminal.detach",
                Params(terminalId: claim.terminalID)
            )
        }
    }

    func writeTerminal(
        _ id: String,
        data: String,
        intent: TerminalPresentationIntent
    ) async throws {
        guard terminalState.owns(intent) else { throw CancellationError() }
        struct Params: Codable { let terminalId, writeId, data, commandId: String }
        struct Response: Codable { let written: Bool }
        let identity = uuidSource.next().uuidString
        let params = Params(terminalId: id, writeId: identity, data: data, commandId: identity)
        let _: Response = try await confirmedMutation(method: "terminal.write", commandId: identity) {
            try await client.request("terminal.write", params)
        }
    }

    func resizeTerminal(
        _ id: String,
        columns: Int,
        rows: Int,
        intent: TerminalPresentationIntent
    ) async throws {
        guard terminalState.owns(intent) else { throw CancellationError() }
        struct Params: Codable { let terminalId: String; let columns, rows: Int; let commandId: String }
        struct Response: Codable { let resized: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(terminalId: id, columns: columns, rows: rows, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "terminal.resize", commandId: commandID) {
            try await client.request("terminal.resize", params)
        }
    }

    func terminateTerminal(_ id: String, intent: TerminalPresentationIntent) async throws {
        guard terminalState.owns(intent) else { throw CancellationError() }
        struct Params: Codable { let terminalId, commandId: String }
        struct Response: Codable { let terminated: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(terminalId: id, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "terminal.terminate", commandId: commandID) {
            try await client.request("terminal.terminate", params)
        }
    }

    func handle(_ event: GatewayEvent) async {
        await handle(event, connectionID: nil)
    }

    private func handle(_ event: GatewayEvent, connectionID: Int?) async {
        guard lifecyclePhase.admitsWork else { return }
        if let connectionID, gatewayConnectionID != connectionID { return }
        if event.topic.hasPrefix("session."), event.topic != "session.listChanged", event.topic != "session.summary" {
            switch sessionSynchronization.admit(event) {
            case .deliver(let event):
                await handleDeliveredEvent(event)
            case .buffered:
                break
            case .overflow(let sessionID):
                _ = await synchronizeSession(sessionID, operation: .sessionResync)
            }
            return
        }
        await handleDeliveredEvent(event)
    }

    private func handleDeliveredEvent(_ event: GatewayEvent) async {
        switch event.topic {
        case "transport.disconnected", "system.stopping":
            gatewayConnectionID = nil
            invalidateSessionConnectionOwnership()
            liveSessionSummaryUpdates.removeAll()
            sessions = sessions.map(\.safeCachedProjection)
            requestReconnect()
        case "transport.resyncRequired":
            if let sessionID = event.sessionId ?? subscribedSessionID {
                _ = await synchronizeSession(sessionID, operation: .sessionResync)
            }
        case let topic where topic.hasPrefix("session."):
            if let sessionID = reduceSessionEvent(event) {
                _ = await synchronizeSession(sessionID, operation: .sessionResync)
            }
        case "auth.prompt":
            parseAuthPrompt(event.payload)
        case "auth.event":
            parseAuthEvent(event.payload)
        case "auth.completed":
            authPrompt = nil
            authEvent = nil
            let operationID = event.payload.objectValue?["operationId"]?.stringValue
            if let target = operationID.flatMap({ providerCatalogTargetByAuthOperation.removeValue(forKey: $0) }) {
                await refreshProviders(target: target)
            }
            if event.payload.objectValue?["success"]?.boolValue == false {
                lastError = event.payload.objectValue?["error"]?.stringValue
            }
        case "settings.changed":
            settingsInvalidationGeneration &+= 1
        case "trust.changed":
            trustRevision &+= 1
            settingsInvalidationGeneration &+= 1
        case "providers.changed":
            providerInvalidationGeneration &+= 1
        case "packages.changed":
            packageInvalidationGeneration &+= 1
        case "models.customChanged":
            customModelInvalidationGeneration &+= 1
        case "packages.progress", "packages.completed":
            postNotice(
                event.topic == "packages.completed" ? "Package operation completed" : "Updating agent package…",
                replacing: .packageProgress
            )
        case "terminal.output":
            if let connectionID = gatewayConnectionID,
               let object = event.payload.objectValue,
               let terminalID = object["terminalId"]?.stringValue,
               let sequence = object["sequence"]?.intValue,
               let data = object["data"]?.stringValue,
               case .gap = terminalState.admitOutput(
                terminalID: terminalID,
                sequence: sequence,
                data: data,
                connectionID: connectionID
               ) {
                reconcileTerminal(terminalID)
            }
        case "terminal.exit":
            if let connectionID = gatewayConnectionID,
               let id = event.payload.objectValue?["terminalId"]?.stringValue {
                _ = terminalState.admitExit(
                    terminalID: id,
                    sequence: event.payload.objectValue?["sequence"]?.intValue,
                    exitCode: event.payload.objectValue?["exitCode"]?.intValue,
                    exitedAt: ISO8601DateFormatter().string(from: .now),
                    connectionID: connectionID
                )
            }
        default:
            break
        }
    }

    private func reduceSessionEvent(_ event: GatewayEvent) -> String? {
        switch event.topic {
        case "session.summary":
            if case .sessionSummary(let update) = event.preparation {
                apply(update)
            }
        case "session.listChanged":
            scheduleSessionListRefresh()
        case "session.snapshot":
            guard case .sessionSnapshot(let snapshot) = event.preparation else { break }
            let current = event.sessionId.flatMap { snapshots[$0] }
            let hasLiveAuthority = event.sessionId.map(ownsLiveSnapshotEvent) ?? false
            switch SessionSnapshotEventAdmission.evaluate(
                eventSessionID: event.sessionId,
                hasLiveAuthority: hasLiveAuthority,
                current: current,
                incoming: snapshot
            ) {
            case .install:
                installLiveSnapshot(snapshot)
            case .ignore:
                break
            case .resynchronize(let sessionID):
                if !sessionSynchronization.markRetryRequired(sessionID: sessionID) {
                    return sessionID
                }
            }
        case "session.progress":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  case .progress(let item)? = event.preparedSessionEvent?.data,
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.streaming = item
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.toolProgress":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  case .toolProgress(let tool)? = event.preparedSessionEvent?.data,
                  var snapshot = snapshots[sessionID] else { break }
            if let index = snapshot.toolExecutions.firstIndex(where: { $0.toolCallId == tool.toolCallId }) {
                guard isNewerToolState(tool, than: snapshot.toolExecutions[index]) else {
                    advance(&snapshot, envelope)
                    snapshots[sessionID] = snapshot
                    break
                }
                snapshot.toolExecutions[index] = tool
            } else {
                snapshot.toolExecutions.append(tool)
            }
            snapshot.toolExecutions.sort(by: toolExecutionOrder)
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.interactions":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  case .interactions(let interactions)? = event.preparedSessionEvent?.data,
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.extensionUI.pendingInteractions = interactions
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.status":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  let object = envelope.data.objectValue,
                  let key = object["key"]?.stringValue,
                  var snapshot = snapshots[sessionID] else { break }
            if let text = object["text"]?.stringValue { snapshot.extensionUI.statuses[key] = text }
            else { snapshot.extensionUI.statuses.removeValue(forKey: key) }
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.working":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  let object = envelope.data.objectValue,
                  var snapshot = snapshots[sessionID] else { break }
            if object.keys.contains("message") { snapshot.extensionUI.working.message = object["message"]?.stringValue }
            if let visible = object["visible"]?.boolValue { snapshot.extensionUI.working.visible = visible }
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.thinkingLabel":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.extensionUI.hiddenThinkingLabel = envelope.data.objectValue?["label"]?.stringValue
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.widget":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  case .widget(let key, let widget)? = event.preparedSessionEvent?.data,
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.extensionUI.widgets.removeAll { $0.key == key }
            if let widget { snapshot.extensionUI.widgets.append(widget) }
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.title":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.extensionUI.title = envelope.data.objectValue?["title"]?.stringValue
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.editorText":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  let object = envelope.data.objectValue,
                  let rawAction = object["action"]?.stringValue,
                  let action = EditorRequest.Action(rawValue: rawAction),
                  let text = object["text"]?.stringValue,
                  let fullText = object["fullText"]?.stringValue,
                  let editorRevision = object["revision"]?.intValue,
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.extensionUI.editorRevision = editorRevision
            snapshot.extensionUI.editorText = fullText
            if let target = presentationTarget(for: sessionID),
               ownsPresentation(target) {
                editorRequestByTarget[target] = .init(
                    sessionId: sessionID,
                    presentationGeneration: target.generation,
                    revision: editorRevision,
                    action: action,
                    text: text,
                    fullText: fullText
                )
            }
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.notification":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            if let message = envelope.data.objectValue?["message"]?.stringValue { postNotice(message) }
            advanceSessionCursor(sessionID, envelope)
        case "session.operationFailed", "session.extensionError":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            if let message = envelope.data.objectValue?["message"]?.stringValue { lastError = message }
            else if case .string(let message) = envelope.data { lastError = message }
            advanceSessionCursor(sessionID, envelope)
        case "session.compaction", "session.retry", "session.bashProgress":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            advanceSessionCursor(sessionID, envelope)
        case "session.structureChanged":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            if envelope.data.objectValue?["branchChanged"]?.boolValue == true {
                sessionSynchronization.requireFreshInstall(sessionID: sessionID)
            }
            advanceSessionCursor(sessionID, envelope)
            sessionStructureRevisions[sessionID, default: 0] &+= 1
            sessionContextRevisions[sessionID, default: 0] &+= 1
        case "session.contextChanged":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            advanceSessionCursor(sessionID, envelope)
            sessionContextRevisions[sessionID, default: 0] &+= 1
        case "session.resourcesChanged":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            advanceSessionCursor(sessionID, envelope)
            sessionResourceRevisions[sessionID, default: 0] &+= 1
            sessionContextRevisions[sessionID, default: 0] &+= 1
        default:
            if let (sessionID, envelope) = admitSessionEvent(event) {
                // Unknown sequenced session events still advance the cursor.
                advanceSessionCursor(sessionID, envelope)
            }
        }
        return nil
    }

    private func admitSessionEvent(_ event: GatewayEvent) -> (String, SessionEventEnvelope)? {
        guard let sessionID = event.sessionId,
              let envelope = event.preparedSessionEvent?.envelope,
              let snapshot = snapshots[sessionID] else { return nil }
        guard envelope.runtimeGeneration == snapshot.runtimeGeneration else {
            if !sessionSynchronization.markRetryRequired(sessionID: sessionID) {
                Task { await synchronizeSession(sessionID, operation: .sessionResync) }
            }
            return nil
        }
        guard envelope.eventSequence > snapshot.eventSequence else { return nil }
        guard envelope.eventSequence == snapshot.eventSequence + 1 else {
            if !sessionSynchronization.markRetryRequired(sessionID: sessionID) {
                Task { await synchronizeSession(sessionID, operation: .sessionResync) }
            }
            return nil
        }
        return (sessionID, envelope)
    }

    private func ownsLiveSnapshotEvent(sessionID: String) -> Bool {
        guard subscribedSessionID == sessionID,
              subscriptionTokenBySession[sessionID] != nil else { return false }
        let ownsMountedAuthority = mountedPresentationGenerationBySession[sessionID].map {
            authoritativeSessionIDs.contains(sessionID)
                && ownsPresentation(SessionPresentationTarget(sessionID: sessionID, generation: $0))
        } ?? false
        let ownsSynchronization = sessionSynchronization.intent(sessionID: sessionID).map {
            ownsSynchronizationIntent($0, sessionID: sessionID)
        } ?? false
        return ownsMountedAuthority || ownsSynchronization
    }

    private func isNewerToolState(_ candidate: ToolExecutionState, than current: ToolExecutionState) -> Bool {
        if let candidateSequence = candidate.progressSequence,
           let currentSequence = current.progressSequence,
           candidateSequence != currentSequence { return candidateSequence > currentSequence }
        if candidate.updatedAt != current.updatedAt { return candidate.updatedAt > current.updatedAt }
        let rank: (ToolExecutionState.Status) -> Int = { status in
            switch status { case .running: 0; case .completed, .failed: 1 }
        }
        return rank(candidate.status) >= rank(current.status)
    }

    private func toolExecutionOrder(_ left: ToolExecutionState, _ right: ToolExecutionState) -> Bool {
        if let leftOrder = left.order, let rightOrder = right.order, leftOrder != rightOrder { return leftOrder < rightOrder }
        if left.order != nil, right.order == nil { return true }
        if left.order == nil, right.order != nil { return false }
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        return left.toolCallId < right.toolCallId
    }

    private func advance(_ snapshot: inout SessionSnapshot, _ envelope: SessionEventEnvelope) {
        snapshot.eventSequence = envelope.eventSequence
        snapshot.revision = max(snapshot.revision, envelope.revision)
    }

    private func advanceSessionCursor(_ sessionID: String, _ envelope: SessionEventEnvelope) {
        guard var snapshot = snapshots[sessionID] else { return }
        advance(&snapshot, envelope)
        snapshots[sessionID] = snapshot
    }

    @discardableResult
    private func synchronizeSession(
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
            guard let mountedGeneration = presentationGeneration
                ?? mountedPresentationGenerationBySession[sessionID] else { return false }
            intent = .reconnect(presentationGeneration: mountedGeneration)
        }

        while !Task.isCancelled {
            let lease = sessionSynchronization.acquire(sessionID: sessionID, intent: intent)
            switch lease.role {
            case .join:
                return await lease.sharedValue()
            case .retryAfterCurrent:
                _ = await lease.sharedValue()
            case .leader:
                sessionSynchronization.prepareLeaderAttempt(lease)
                return await performSessionSynchronization(
                    sessionID: sessionID,
                    lease: lease,
                    operation: operation
                )
            }
        }
        return false
    }

    private enum SessionSynchronizationAttemptOutcome {
        case success
        case retry
        case failed
    }

    private func performSessionSynchronization(
        sessionID: String,
        lease: SessionSynchronizationCoordinator.Lease,
        operation: PerformanceOperation
    ) async -> Bool {
        var nextOperation = operation
        for _ in 0..<3 {
            guard !Task.isCancelled,
                  sessionSynchronization.owns(lease),
                  ownsSynchronizationIntent(lease.intent, sessionID: sessionID) else {
                sessionSynchronization.complete(lease, outcome: false)
                return false
            }
            switch await performSessionSynchronizationAttempt(
                sessionID: sessionID,
                lease: lease,
                operation: nextOperation
            ) {
            case .success:
                sessionSynchronization.complete(lease, outcome: true)
                removeNotice(.sessionCatchUp)
                saveCache()
                return true
            case .retry:
                sessionSynchronization.restartBuffer(for: lease)
                nextOperation = .sessionResync
            case .failed:
                sessionSynchronization.complete(lease, outcome: false)
                return false
            }
        }
        if subscriptionTokenBySession[sessionID] != nil {
            await closeSubscription(sessionID)
        }
        sessionSynchronization.complete(lease, outcome: false)
        postNotice(Self.sessionCatchUpNotice, replacing: .sessionCatchUp)
        return false
    }

    private func performSessionSynchronizationAttempt(
        sessionID: String,
        lease: SessionSynchronizationCoordinator.Lease,
        operation: PerformanceOperation
    ) async -> SessionSynchronizationAttemptOutcome {
        let interval = performanceSignposts.begin(operation)
        var result = PerformanceResult.failure
        var metrics = PerformanceMetrics.none
        defer { performanceSignposts.end(interval, result: result, metrics: metrics) }
        var provisionalSubscriptionToken: String?
        do {
            try Task.checkCancellation()
            struct Params: Codable { let sessionId: String }
            let response: SessionOpenResponse = try await client.request(
                "session.open",
                Params(sessionId: sessionID),
                timeout: .seconds(60)
            )
            provisionalSubscriptionToken = response.subscriptionToken
            if subscribedSessionID == sessionID {
                subscribedSessionID = nil
                subscriptionTokenBySession[sessionID] = nil
            }
            guard sessionSynchronization.owns(lease),
                  ownsSynchronizationIntent(lease.intent, sessionID: sessionID) else {
                await closeProvisionalSubscription(sessionID, token: response.subscriptionToken)
                result = .discarded
                return .failed
            }

            try await acknowledgeSessionSync(sessionID: sessionID, syncToken: response.syncToken)
            try Task.checkCancellation()
            guard sessionSynchronization.owns(lease),
                  ownsSynchronizationIntent(lease.intent, sessionID: sessionID) else {
                await closeProvisionalSubscription(sessionID, token: response.subscriptionToken)
                result = .discarded
                return .failed
            }

            let mode: SessionSnapshotInstallMode
            switch lease.intent {
            case .presentation:
                mode = .freshPresentation
            case .reconnect:
                mode = sessionSynchronization.consumeFreshInstallRequirement(sessionID: sessionID)
                    ? .freshPresentation
                    : .reconnect
            }
            let installed = Self.installingSnapshot(
                current: snapshots[sessionID],
                authoritative: response.session,
                mode: mode
            )
            let cursor = SessionSynchronizationCoordinator.Cursor(
                runtimeGeneration: installed.runtimeGeneration,
                eventSequence: installed.eventSequence
            )
            guard sessionSynchronization.owns(lease),
                  let firstReplay = sessionSynchronization.drainBufferedEvents(
                    for: lease,
                    baseline: cursor
                  ),
                  SessionSynchronizationCoordinator.isContiguous(firstReplay, after: cursor) else {
                if case .freshPresentation = mode {
                    sessionSynchronization.requireFreshInstall(sessionID: sessionID)
                }
                await closeProvisionalSubscription(sessionID, token: response.subscriptionToken)
                result = .discarded
                return .retry
            }

            // Baseline and already-drained contiguous suffix publish in one
            // MainActor turn; no provisional token or snapshot escapes earlier.
            selectedSessionID = sessionID
            subscribedSessionID = sessionID
            subscriptionTokenBySession[sessionID] = response.subscriptionToken
            snapshots[sessionID] = installed
            updateSessionSummary(from: installed)
            provisionalSubscriptionToken = nil

            for event in firstReplay { _ = reduceSessionEvent(event) }

            if sessionSynchronization.consumeRetryRequirement(for: lease) {
                result = .discarded
                return .retry
            }
            result = .success
            metrics = PerformanceMetrics(itemCount: firstReplay.count)
            return .success
        } catch {
            if Task.isCancelled || error is CancellationError { result = .cancelled }
            if let provisionalSubscriptionToken {
                await closeProvisionalSubscription(sessionID, token: provisionalSubscriptionToken)
            }
            if let failure = error as? GatewayFailure,
               failure.retryable || failure.code == "response_too_large" {
                postNotice(Self.sessionCatchUpNotice, replacing: .sessionCatchUp)
            } else {
                surface(error)
            }
            return .failed
        }
    }

    private func ownsSynchronizationIntent(
        _ intent: SessionSynchronizationCoordinator.Intent,
        sessionID: String
    ) -> Bool {
        switch intent {
        case .presentation(let generation):
            return presentationOpenGeneration == generation && selectedSessionID == sessionID
        case .reconnect(let presentationGeneration):
            return ownsPresentation(SessionPresentationTarget(
                sessionID: sessionID,
                generation: presentationGeneration
            ))
        }
    }

    private func acknowledgeSessionSync(sessionID: String, syncToken: String) async throws {
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

    private func parseAuthPrompt(_ payload: JSONValue) {
        guard let root = payload.objectValue,
              let operationID = root["operationId"]?.stringValue,
              let promptID = root["promptId"]?.stringValue,
              let prompt = root["prompt"]?.objectValue,
              let rawKind = prompt["type"]?.stringValue,
              let kind = AuthPromptState.Kind(rawValue: rawKind),
              let message = prompt["message"]?.stringValue else { return }
        let options = (prompt["options"].flatMap { value -> [JSONValue]? in
            guard case .array(let array) = value else { return nil }; return array
        } ?? []).compactMap { value -> AuthPromptState.Option? in
            guard let item = value.objectValue, let id = item["id"]?.stringValue, let label = item["label"]?.stringValue else { return nil }
            return .init(id: id, label: label, description: item["description"]?.stringValue)
        }
        authPrompt = AuthPromptState(
            id: promptID,
            operationId: operationID,
            kind: kind,
            message: message,
            placeholder: prompt["placeholder"]?.stringValue,
            options: options
        )
    }

    private func parseAuthEvent(_ payload: JSONValue) {
        guard let root = payload.objectValue,
              let operationID = root["operationId"]?.stringValue,
              let event = root["event"]?.objectValue,
              let rawKind = event["type"]?.stringValue,
              let kind = AuthEventState.Kind(rawValue: rawKind) else { return }
        let links: [AuthEventState.Link] = (event["links"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue,
                  let rawURL = object["url"]?.stringValue,
                  let url = URL(string: rawURL) else { return nil }
            return .init(url: url, label: object["label"]?.stringValue)
        }
        authEvent = .init(
            operationId: operationID,
            kind: kind,
            message: event["message"]?.stringValue,
            links: links,
            url: event["url"]?.stringValue.flatMap(URL.init(string:)),
            instructions: event["instructions"]?.stringValue,
            userCode: event["userCode"]?.stringValue,
            verificationURL: event["verificationUri"]?.stringValue.flatMap(URL.init(string:)),
            intervalSeconds: event["intervalSeconds"]?.intValue,
            expiresInSeconds: event["expiresInSeconds"]?.intValue
        )
    }

    private func installLiveSnapshot(_ snapshot: SessionSnapshot) {
        let installed = snapshots[snapshot.sessionId].map { current in
            Self.mergingVisibleTranscript(current: current, authoritative: snapshot)
        } ?? snapshot
        snapshots[snapshot.sessionId] = installed
        // Persist merged history only at explicit paging/session boundaries.
        // High-frequency live snapshots must not repeatedly encode an
        // arbitrarily expanded transcript on the MainActor.
        if installed.transcriptStart == snapshot.transcriptStart,
           installed.transcript.count == snapshot.transcript.count {
            saveCache()
        }
        updateSessionSummary(from: installed)
    }

    private func updateSessionSummary(from snapshot: SessionSnapshot) {
        guard let index = sessions.firstIndex(where: { $0.id == snapshot.sessionId }) else { return }
        let current = sessions[index]
        sessions[index] = SessionSummary(
            id: current.id,
            name: snapshot.name,
            cwd: current.cwd,
            kind: current.kind,
            parentSessionId: current.parentSessionId,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            messageCount: current.messageCount,
            firstMessage: current.firstMessage,
            phase: snapshot.phase,
            summaryRevision: current.summaryRevision
        )
    }

    static func installingSnapshot(
        current: SessionSnapshot?,
        authoritative: SessionSnapshot,
        mode: SessionSnapshotInstallMode
    ) -> SessionSnapshot {
        switch mode {
        case .freshPresentation:
            return authoritative
        case .reconnect:
            guard let current else { return authoritative }
            if current.runtimeGeneration == authoritative.runtimeGeneration,
               authoritative.eventSequence < current.eventSequence {
                return current
            }
            return mergingVisibleTranscript(current: current, authoritative: authoritative)
        }
    }

    /// Authoritative snapshots own current runtime state, but a live replacement
    /// must not evict canonical rows that this open chat already loaded. When the
    /// new tail overlaps the current branch, preserve the loaded prefix and append
    /// only authoritative newer rows. A non-overlapping tail is a real branch or
    /// runtime change and replaces the old projection instead of fabricating a
    /// combined history.
    static func mergingVisibleTranscript(
        current: SessionSnapshot,
        authoritative: SessionSnapshot
    ) -> SessionSnapshot {
        guard current.sessionId == authoritative.sessionId,
              current.runtimeGeneration == authoritative.runtimeGeneration,
              !current.transcript.isEmpty else { return authoritative }
        guard !authoritative.transcript.isEmpty else {
            // A pathological active projection may temporarily omit canonical
            // rows to preserve the connection. Keep this chat's loaded branch;
            // idle/non-overlapping replacement remains authoritative.
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
            let currentEnd = currentStart + current.transcript.count
            guard authoritative.phase.isActive, authoritativeStart >= currentEnd else { return authoritative }
            var merged = authoritative
            merged.transcript = current.transcript + authoritative.transcript
            merged.transcriptStart = currentStart
            merged.transcriptTotal = max(
                authoritative.transcriptTotal ?? authoritativeStart + authoritative.transcript.count,
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
        merged.transcriptTotal = max(
            authoritative.transcriptTotal ?? authoritative.transcript.count,
            merged.transcriptStart! + merged.transcript.count
        )
        return merged
    }

    private func apply(_ update: SessionSummaryUpdate) {
        if let current = liveSessionSummaryUpdates[update.sessionId], update.summaryRevision <= current.summaryRevision { return }
        if let summary = sessions.first(where: { $0.id == update.sessionId }),
           update.summaryRevision <= (summary.summaryRevision ?? 0) { return }
        liveSessionSummaryUpdates[update.sessionId] = update
        guard let index = sessions.firstIndex(where: { $0.id == update.sessionId }) else {
            scheduleSessionListRefresh()
            return
        }
        sessions[index] = applying(update, to: sessions[index])
        saveCache()
    }

    private func applying(_ update: SessionSummaryUpdate, to summary: SessionSummary) -> SessionSummary {
        SessionSummary(
            id: summary.id,
            name: update.name,
            cwd: summary.cwd,
            kind: summary.kind,
            parentSessionId: summary.parentSessionId,
            createdAt: summary.createdAt,
            updatedAt: update.updatedAt,
            messageCount: update.messageCount,
            firstMessage: update.firstMessage,
            phase: update.phase,
            summaryRevision: update.summaryRevision
        )
    }

    private func scheduleSessionListRefresh() {
        guard lifecyclePhase.admitsWork else { return }
        refreshTask?.cancel()
        let generation = lifecyclePhase.generation
        let clock = self.clock
        refreshTask = Task { [weak self] in
            do { try await clock.sleep(.milliseconds(150)) }
            catch { return }
            guard let self, self.admitsLifecycle(generation) else { return }
            await self.refreshSessions()
            guard self.admitsLifecycle(generation) else { return }
            self.refreshTask = nil
        }
    }

    private func clearLiveConnectionProjection() {
        noticeStore.removeAll()
        liveSessionSummaryUpdates.removeAll()
        terminalState.clear()
        sessionStructureRevisions.removeAll()
        sessionContextRevisions.removeAll()
        sessionResourceRevisions.removeAll()
    }

    private func reconcileTerminal(_ terminalID: String) {
        guard let connectionID = gatewayConnectionID,
              let lease = terminalState.beginReconciliation(
                terminalID: terminalID,
                connectionID: connectionID
              ) else { return }
        let after = terminalState.replay(for: terminalID).chunks.last?.sequence ?? 0
        let lifecycleGeneration = lifecyclePhase.generation
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.performTerminalAttach(
                terminalID,
                after: after,
                lease: lease,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    private func reattachTerminals() async {
        guard let connectionID = gatewayConnectionID else { return }
        for terminalID in terminalState.attachedTerminalIDs() {
            guard let lease = terminalState.beginReattachment(
                terminalID: terminalID,
                connectionID: connectionID
            ) else { continue }
            let after = terminalState.replay(for: terminalID).chunks.last?.sequence ?? 0
            _ = try? await performTerminalAttach(
                terminalID,
                after: after,
                lease: lease,
                lifecycleGeneration: lifecyclePhase.generation
            )
        }
    }

    private func reconcileSelection() {
        defaultWorkspace = UserDefaults.standard.string(forKey: "defaultWorkspace.v1")
        loadHidden()
        selectedSessionID = SessionSelectionPolicy.reconcile(
            selected: selectedSessionID,
            visibleIDs: Set(visibleSessions.map(\.id)),
            locallyCreatedUnindexedIDs: locallyCreatedUnindexedSessionIDs
        )
    }

    private var hiddenKey: String { "hiddenSessions.\(profiles.selected?.id ?? "none")" }
    private func loadHidden() { hiddenSessionIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
    private func persistHidden() { UserDefaults.standard.set(Array(hiddenSessionIDs), forKey: hiddenKey) }

    private func confirmedMutation<Response: Codable>(
        method: String,
        commandId: String,
        send: () async throws -> Response
    ) async throws -> Response {
        let value = try await confirmedMutationValue(method: method, commandId: commandId) {
            try JSONValue.encode(try await send())
        }
        return try value.decode(Response.self)
    }

    private func confirmedMutationValue(
        method: String,
        commandId: String,
        send: () async throws -> JSONValue
    ) async throws -> JSONValue {
        let lifecycleGeneration = lifecyclePhase.generation
        try requireLifecycle(lifecycleGeneration)
        do {
            let value = try await send()
            try requireLifecycle(lifecycleGeneration)
            return value
        } catch let uncertain as GatewayPossiblySentError {
            let original = uncertain.failure
            if Task.isCancelled || !admitsLifecycle(lifecycleGeneration) {
                throw Self.uncertainMutationOutcome(
                    method: method,
                    commandId: commandId,
                    lastFailure: original
                )
            }
            let interval = performanceSignposts.begin(.receiptResolution)
            var result = PerformanceResult.failure
            defer {
                if Task.isCancelled { result = .cancelled }
                performanceSignposts.end(interval, result: result, metrics: .none)
            }
            let deadline = clock.now() + .seconds(90)
            var lastFailure: GatewayFailure = original
            while clock.now() < deadline {
                if Task.isCancelled || !admitsLifecycle(lifecycleGeneration) {
                    result = .cancelled
                    throw Self.uncertainMutationOutcome(
                        method: method,
                        commandId: commandId,
                        lastFailure: lastFailure
                    )
                }
                guard await waitForConnected(
                    until: deadline,
                    lifecycleGeneration: lifecycleGeneration
                ) else { break }
                do {
                    let status: CommandStatusResponse = try await client.request(
                        "command.status",
                        CommandStatusParams(method: method, commandId: commandId),
                        timeout: .seconds(10)
                    )
                    try requireLifecycle(lifecycleGeneration)
                    switch status.status {
                    case "completed":
                        guard let resolved = status.result else {
                            throw GatewayFailure(code: "invalid_response", message: "The completed command did not include a result.", retryable: false, details: nil)
                        }
                        result = .success
                        return resolved
                    case "missing":
                        do {
                            guard admitsLifecycle(lifecycleGeneration),
                                  Self.admitsReceiptReplay(taskIsCancelled: Task.isCancelled) else {
                                throw Self.uncertainMutationOutcome(
                                    method: method,
                                    commandId: commandId,
                                    lastFailure: lastFailure
                                )
                            }
                            let resolved = try await send()
                            try requireLifecycle(lifecycleGeneration)
                            result = .success
                            return resolved
                        }
                        catch let retry as GatewayPossiblySentError {
                            lastFailure = retry.failure
                        }
                    case "pending":
                        break
                    default:
                        throw GatewayFailure(code: "invalid_response", message: "Tron returned an unknown command status.", retryable: false, details: nil)
                    }
                } catch let failure as GatewayPossiblySentError {
                    lastFailure = failure.failure
                }
                do { try await clock.sleep(.milliseconds(250)) }
                catch { break }
            }
            if Task.isCancelled { result = .cancelled }
            throw Self.uncertainMutationOutcome(
                method: method,
                commandId: commandId,
                lastFailure: lastFailure
            )
        }
    }

    private func waitForConnected(
        until deadline: ContinuousClock.Instant,
        lifecycleGeneration: Int
    ) async -> Bool {
        while clock.now() < deadline {
            guard !Task.isCancelled, admitsLifecycle(lifecycleGeneration) else { return false }
            if connectionState == .connected { return true }
            if connectionState == .unauthorized || connectionState == .unpaired { return false }
            if reconnectTask == nil { scheduleReconnect(immediate: true) }
            do { try await clock.sleep(.milliseconds(100)) }
            catch { return false }
        }
        return false
    }

    static func admitsReceiptReplay(taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled
    }

    private static func uncertainMutationOutcome(
        method: String,
        commandId: String,
        lastFailure: GatewayFailure
    ) -> GatewayFailure {
        GatewayFailure(
            code: "outcome_unknown",
            message: "Tron may have accepted this command. Verify the authoritative state before trying again.",
            retryable: false,
            details: .object([
                "commandId": .string(commandId),
                "method": .string(method),
                "lastFailure": .string(lastFailure.message),
            ])
        )
    }

    private func measure<Value>(
        _ operation: PerformanceOperation,
        body: () async throws -> (Value, PerformanceMetrics)
    ) async throws -> Value {
        let interval = performanceSignposts.begin(operation)
        do {
            let (value, metrics) = try await body()
            performanceSignposts.end(interval, result: .success, metrics: metrics)
            return value
        } catch {
            let result = PerformanceResult.forFailure(error)
            performanceSignposts.end(interval, result: result, metrics: .none)
            throw error
        }
    }

    static let sessionCatchUpNotice = "Live session view is catching up; the run continues on your Mac."

    static func shouldSurface(_ error: Error) -> Bool {
        if error is CancellationError || error is GatewayPossiblySentError { return false }
        if let failure = error as? GatewayFailure {
            return !["disconnected", "closed", "replaced", "timeout", "event_overflow"].contains(failure.code)
        }
        if let urlError = error as? URLError {
            return ![
                .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
                .cannotLoadFromNetwork, .backgroundSessionWasDisconnected,
            ].contains(urlError.code)
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain {
            // Connection aborted/reset, socket unavailable/timed out, and
            // host/network down are transport lifecycle, not user actions.
            return ![53, 54, 57, 60, 61, 64, 65].contains(cocoaError.code)
        }
        return true
    }

    private func surface(_ error: Error) {
        guard Self.shouldSurface(error) else { return }
        lastError = error.localizedDescription
    }

    private func loadCache(profileID: String, lifecycleGeneration: Int) async {
        let value = await cache.load(profileID: profileID)
        guard admitsLifecycle(lifecycleGeneration), profiles.selected?.id == profileID else { return }
        sessions = value.sessions.map(\.safeCachedProjection)
        snapshots = Dictionary(uniqueKeysWithValues: value.snapshots.map { ($0.sessionId, $0) })
        reconcileSelection()
    }

    private func saveCache() {
        guard let id = profiles.selected?.id else { return }
        let sessions = sessions
        let values = Array(snapshots.values)
        Task { await cache.save(profileID: id, sessions: sessions, snapshots: values) }
    }

    private struct MutationResponse: Codable {
        let updated: Bool?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let object = try container.decode([String: Bool].self)
            updated = object.values.first
        }
    }
}
