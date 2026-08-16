import Foundation
import Observation
import UIKit

final class ChatMediaMemoryPressureObserver: @unchecked Sendable {
    private let task: Task<Void, Never>

    @MainActor
    init(loader: ChatMediaLoader) {
        task = Self.observe(loader: loader)
    }

    #if HOSTED_TEST
    @MainActor
    init(
        loader: ChatMediaLoader,
        hostedOnReady: @escaping @MainActor @Sendable () async -> Void,
        hostedOnHandled: @escaping @MainActor @Sendable () async -> Void
    ) {
        task = Self.observe(
            loader: loader,
            onReady: hostedOnReady,
            onHandled: hostedOnHandled
        )
    }
    #endif

    @MainActor
    private static func observe(
        loader: ChatMediaLoader,
        onReady: (@MainActor @Sendable () async -> Void)? = nil,
        onHandled: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Task<Void, Never> {
        Task { @MainActor [weak loader] in
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            )
            await onReady?()
            for await _ in notifications {
                guard !Task.isCancelled else { return }
                loader?.removeAll()
                await onHandled?()
            }
        }
    }

    deinit { task.cancel() }
}

@MainActor
@Observable
final class AppModel {
    typealias SessionSnapshotInstallMode = SessionSnapshotInstallationMode
    typealias ConnectionState = GatewayConnectionState

    typealias AuthPromptState = ProviderAuthPromptState
    typealias AuthEventState = ProviderAuthEventState

    struct SessionNavigationRoute: Identifiable, Hashable {
        let sessionID: String
        let editorText: String?
        fileprivate let gatewayProfileID: String?
        fileprivate let gatewayLifecycleGeneration: Int?
        var id: String { sessionID }

        init(
            sessionID: String,
            editorText: String?,
            gatewayProfileID: String? = nil,
            gatewayLifecycleGeneration: Int? = nil
        ) {
            self.sessionID = sessionID
            self.editorText = editorText
            self.gatewayProfileID = gatewayProfileID
            self.gatewayLifecycleGeneration = gatewayLifecycleGeneration
        }
    }

    typealias SessionPresentationTarget = SessionPresentationIdentity

    typealias SessionOpenResponse = GatewaySessionOpenResponse
    typealias PairingCommit = GatewayPairingCommit
    typealias ProfileTokenLookup = GatewayProfileTokenLookup

    private struct CacheCheckpoint: Sendable {
        let profileID: String
        let generation: Int
        let sessions: [SessionSummary]
        let snapshots: [SessionSnapshot]
    }

    private let lifecycle: GatewayLifecycleCoordinator
    var client: GatewayClient { lifecycle.client }
    var profiles: GatewayProfileStore { lifecycle.profiles }
    private let cache: SnapshotCache
    private let clock: MonotonicClock
    private let uuidSource: UUIDSource
    private let performanceSignposts: any PerformanceSignposting
    private let exportArtifacts: SessionExportArtifactStore
    private let mutationExecutor: ConfirmedMutationExecutor
    private let sessionMutations: SessionMutationService
    private let sessionImports: SessionImportCoordinator
    private let terminal: TerminalCoordinator
    private let settingsTrust: SettingsTrustCoordinator
    private let providerAuth: ProviderAuthCoordinator
    private let packageConfiguration: PackageConfigurationCoordinator
    private let customModelConfiguration: CustomModelConfigurationCoordinator
    let composerDrafts: ComposerDraftCoordinator
    let gatewayDiagnostics: GatewayDiagnosticsService
    let chatMedia: ChatMediaLoader
    private let chatMediaMemoryPressureObserver: ChatMediaMemoryPressureObserver

    var connectionState: ConnectionState { lifecycle.connectionState }
    /// False only while the first launch credential/connection decision is
    /// unresolved. The UI must not infer "unpaired" from the temporary default.
    var hasResolvedLaunchState: Bool { lifecycle.hasResolvedLaunchState }
    var gatewayInfo: GatewayInfo? { lifecycle.gatewayInfo }
    private var gatewayConnectionID: Int? { lifecycle.connectionID }
    private var sessionCatalog = SessionCatalogCoordinator()
    var sessions: [SessionSummary] {
        get { sessionCatalog.sessions }
        set { sessionCatalog.replaceForFacade(newValue) }
    }
    private let sessionPresentation: SessionPresentationStore
    var settingsInvalidationGeneration: Int { settingsTrust.settingsInvalidationGeneration }
    var providerInvalidationGeneration: Int { providerAuth.invalidationGeneration }
    var packageInvalidationGeneration: Int { packageConfiguration.invalidationGeneration }
    var customModelInvalidationGeneration: Int { customModelConfiguration.invalidationGeneration }
    var trustRevision: Int { settingsTrust.trustRevision }
    var pairedDevices: [PairedDevice] = []
    var legacyImportAvailable = false
    var legacyImportedCount = 0
    var workspace: WorkspaceListing?
    var defaultWorkspace: String?
    var authPrompt: AuthPromptState? { providerAuth.prompt }
    var authEvent: AuthEventState? { providerAuth.event }
    private var noticeStore = GlobalNoticeStore()
    var latestNotice: String? { noticeStore.latest }
    var lastError: String?
    var onboardingError: String?
    var context: JSONValue? { sessionPresentation.context }
    var sessionTree: [SessionTreeNode] { sessionPresentation.sessionTree }
    var loadingEarlierTranscript: Bool { sessionPresentation.loadingEarlierTranscript }
    var commands: [CommandInfo] { sessionPresentation.commands }
    var resources: JSONValue? { sessionPresentation.resources }
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

    private var eventTask: Task<Void, Never>?
    private var deviceLoadGeneration = 0
    private var legacyImportLoadGeneration = 0
    private var catalogRefreshTask: Task<SessionCatalogRefreshOutcome, Never>?
    private var catalogRefreshKey: SessionCatalogLoadKey?
    private var catalogRefreshRequestGeneration = 0
    private var catalogInvalidationGeneration = 0
    private var catalogDeferredFollowUpKey: SessionCatalogLoadKey?
    private var sceneAllowsCatalogRefresh = true
    private var cacheCheckpointTask: Task<Void, Never>?
    private var cacheCheckpointTaskGeneration = 0
    private var cacheCheckpointGeneration = 0
    private var pendingCacheCheckpoint: CacheCheckpoint?
    private var hiddenSessionIDs: Set<String> = []
    private var workspaceLoadGeneration = 0

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
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        sessionImportFileAccess: SessionImportFileAccess = .live,
        sessionImportUpload: SessionImportUpload? = nil,
        composerUpload: ComposerUploadOperation? = nil,
        exportArtifacts: SessionExportArtifactStore = SessionExportArtifactStore()
    ) {
        let resolvedPairingCommit = pairingCommit ?? { profile, token in
            try profiles.save(profile, token: token)
        }
        let resolvedProfileTokenLookup = profileTokenLookup ?? { profile in
            profiles.token(for: profile)
        }
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: clock,
            reconnectDelayPolicy: reconnectDelayPolicy,
            uuidSource: uuidSource,
            pairer: pairer,
            pairingCommit: resolvedPairingCommit,
            profileTokenLookup: resolvedProfileTokenLookup
        )
        let mutationExecutor = ConfirmedMutationExecutor(
            client: client,
            lifecycle: lifecycle,
            clock: clock,
            performanceSignposts: performanceSignposts
        )
        let sessionMutations = SessionMutationService(
            client: client,
            executor: mutationExecutor,
            uuidSource: uuidSource
        )
        let settingsTrust = SettingsTrustCoordinator(
            client: client,
            mutationExecutor: mutationExecutor,
            uuidSource: uuidSource
        )
        let providerAuth = ProviderAuthCoordinator(
            client: client,
            mutationExecutor: mutationExecutor,
            uuidSource: uuidSource
        )
        let packageConfiguration = PackageConfigurationCoordinator(
            client: client,
            mutationExecutor: mutationExecutor,
            uuidSource: uuidSource
        )
        let customModelConfiguration = CustomModelConfigurationCoordinator(
            client: client,
            mutationExecutor: mutationExecutor,
            uuidSource: uuidSource
        )
        let sessionPresentation = SessionPresentationStore(
            client: client,
            performanceSignposts: performanceSignposts
        )
        let terminal = TerminalCoordinator(
            client: client,
            lifecycle: lifecycle,
            mutationExecutor: mutationExecutor,
            uuidSource: uuidSource,
            clock: clock,
            performanceSignposts: performanceSignposts,
            installedSubscriptionToken: { sessionPresentation.installedSubscriptionToken(for: $0) }
        )
        let composerDrafts = ComposerDraftCoordinator(
            upload: composerUpload ?? { name, mimeType, data in
                try await client.upload(name: name, mimeType: mimeType, data: data)
            },
            send: { text, sessionID, uploadIDs, behavior in
                try await sessionMutations.prompt(text, sessionID: sessionID, uploadIDs: uploadIDs, behavior: behavior)
            },
            admitsLifecycleGeneration: { lifecycle.admits(.init(generation: $0, connectionID: nil)) }
        )
        let gatewayDiagnostics = GatewayDiagnosticsService(client: client)
        let chatMedia = ChatMediaLoader(
            fetch: { identity in
                let value = try await client.blob(
                    id: identity.blobID,
                    profileID: identity.profileID,
                    connectionID: identity.connectionID,
                    maximumBytes: ChatMediaPolicy.maximumEncodedBytes
                )
                return ChatMediaPayload(data: value.0, mimeType: value.1)
            },
            admits: { identity in
                lifecycle.selectedProfileID == identity.profileID
                    && lifecycle.admits(.init(
                        generation: identity.lifecycleGeneration,
                        connectionID: identity.connectionID
                    ))
            }
        )
        let chatMediaMemoryPressureObserver = ChatMediaMemoryPressureObserver(loader: chatMedia)
        let resolvedSessionImportUpload = sessionImportUpload ?? { name, mimeType, data in
            try await client.upload(name: name, mimeType: mimeType, data: data)
        }
        self.lifecycle = lifecycle
        self.mutationExecutor = mutationExecutor
        self.sessionMutations = sessionMutations
        self.sessionImports = SessionImportCoordinator(
            lifecycle: lifecycle,
            mutations: sessionMutations,
            fileAccess: sessionImportFileAccess,
            upload: resolvedSessionImportUpload
        )
        self.terminal = terminal
        self.settingsTrust = settingsTrust
        self.providerAuth = providerAuth
        self.packageConfiguration = packageConfiguration
        self.customModelConfiguration = customModelConfiguration
        self.composerDrafts = composerDrafts
        self.gatewayDiagnostics = gatewayDiagnostics
        self.chatMedia = chatMedia
        self.chatMediaMemoryPressureObserver = chatMediaMemoryPressureObserver
        self.sessionPresentation = sessionPresentation
        self.cache = cache
        self.clock = clock
        self.uuidSource = uuidSource
        self.performanceSignposts = performanceSignposts
        self.exportArtifacts = exportArtifacts
        Task { try? await exportArtifacts.prune() }
        #if HOSTED_TEST
        if ProcessInfo.processInfo.arguments.contains("--tron-reset-ui-test-state") {
            for profile in profiles.profiles { try? profiles.remove(profile) }
            UserDefaults.standard.removeObject(forKey: "tronSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "piSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "defaultWorkspace.v1")
        }
        #endif
        lifecycle.delegate = self
        sessionPresentation.delegate = self
        settingsTrust.delegate = self
        providerAuth.delegate = self
        packageConfiguration.delegate = self
        customModelConfiguration.delegate = self
        let events = client.events
        eventTask = Task { [weak self, events] in
            for await delivery in events {
                await self?.handle(delivery.event, connectionID: delivery.connectionID)
            }
        }
    }

    func authoritativeSnapshot(for sessionID: String) -> SessionSnapshot? {
        sessionPresentation.authoritativeSnapshot(for: sessionID)
    }

    func chatMediaIdentity(blobID: String) -> ChatMediaIdentity? {
        guard let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
              let profileID = lifecycle.selectedProfileID else { return nil }
        return ChatMediaIdentity(
            profileID: profileID,
            lifecycleGeneration: admission.generation,
            connectionID: connectionID,
            blobID: blobID
        )
    }

    #if HOSTED_TEST
    var selectedSessionID: String? { sessionPresentation.selectedSessionID }
    var selectedSnapshot: SessionSnapshot? { sessionPresentation.snapshot }

    func selectHostedCompatibilitySession(_ sessionID: String?) {
        sessionPresentation.installCompatibilitySelection(sessionID)
    }

    func installHostedSecondaryProjection(
        context: JSONValue?,
        tree: [SessionTreeNode],
        commands: [CommandInfo] = [],
        resources: JSONValue?
    ) {
        sessionPresentation.installHostedSecondaryProjection(
            context: context,
            tree: tree,
            commands: commands,
            resources: resources
        )
    }

    func installHostedSnapshotWithoutPresentation(_ snapshot: SessionSnapshot) {
        sessionPresentation.installHostedSnapshotWithoutPresentation(snapshot)
    }

    func replaceHostedAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        sessionPresentation.replaceHostedSnapshot(snapshot)
    }

    func invalidateHostedPendingPresentation() {
        sessionPresentation.invalidateHostedPendingPresentation()
    }

    func installHostedSubscribedSnapshot(_ snapshot: SessionSnapshot, token: String = "hosted-token") {
        sessionPresentation.installHostedSubscription(snapshot: snapshot, token: token)
        installHostedComposerPresentationIfPossible()
    }

    func installHostedAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        sessionPresentation.installHostedAuthoritativeSnapshot(snapshot)
        installHostedComposerPresentationIfPossible()
    }

    private func installHostedComposerPresentationIfPossible() {
        guard let target = sessionPresentation.mountedTarget,
              let profileID = lifecycle.selectedProfileID,
              let generation = lifecycle.generationAdmission?.generation else { return }
        _ = composerDrafts.installHostedPresentation(
            profileID: profileID, target: target, lifecycleGeneration: generation
        )
    }

    var hostedSessionOpenAdmissionOverride: Bool?

    func connectHostedGateway(profile: GatewayProfile, token: String) async throws {
        try await lifecycle.connectHosted(profile: profile, token: token)
    }

    func installHostedSettings(_ value: JSONValue?, for target: SettingsTarget) {
        settingsTrust.installHostedSettings(value, for: target)
    }

    func setHostedSettingsInvalidationGeneration(_ generation: Int) {
        settingsTrust.setHostedInvalidationGenerations(settings: generation)
    }

    func installHostedProviderCatalog(_ catalog: ProviderCatalog?, for target: ProviderCatalogTarget) {
        providerAuth.installHostedCatalog(catalog, for: target)
    }

    func setHostedProviderInvalidationGeneration(_ generation: Int) {
        providerAuth.setHostedInvalidationGeneration(generation)
    }

    func installHostedPackageInventory(
        _ inventory: PackageInventory?,
        for target: PackageConfigurationTarget
    ) {
        packageConfiguration.installHostedInventory(inventory, for: target)
    }

    func setHostedPackageInvalidationGeneration(_ generation: Int) {
        packageConfiguration.setHostedInvalidationGeneration(generation)
    }

    func installHostedCustomModels(_ value: JSONValue?, for target: CustomModelTarget) {
        customModelConfiguration.installHostedModels(value, for: target)
    }

    func setHostedCustomModelInvalidationGeneration(_ generation: Int) {
        customModelConfiguration.setHostedInvalidationGeneration(generation)
    }

    func installHostedProviderAuthOperation(
        _ operationID: String,
        target: ProviderCatalogTarget = .global
    ) {
        providerAuth.installHostedAuthOperation(operationID, target: target)
    }
    #endif

    func presentationGeneration(for sessionID: String) -> Int? {
        sessionPresentation.presentationGeneration(for: sessionID)
    }

    func chatProjectionGenerations(
        for sessionID: String,
        presentationGeneration: Int
    ) -> (canonical: Int, timeline: Int)? {
        guard sessionPresentation.mountedTarget == SessionPresentationIdentity(
            sessionID: sessionID,
            generation: presentationGeneration
        ) else { return nil }
        return (
            canonical: sessionPresentation.chatCanonicalGeneration,
            timeline: sessionPresentation.chatTimelineGeneration
        )
    }

    func presentationTarget(for sessionID: String) -> SessionPresentationTarget? {
        sessionPresentation.presentationTarget(for: sessionID)
    }

    func ownsPresentation(_ target: SessionPresentationTarget) -> Bool {
        sessionPresentation.owns(target)
    }

    func revokePresentationIntake(_ target: SessionPresentationTarget) {
        composerDrafts.revoke(target)
        sessionPresentation.revokeIntake(target)
    }

    func presentComposerActionError(_ error: Error, target: SessionPresentationTarget) {
        guard composerDrafts.admits(target), !(error is CancellationError) else { return }
        lastError = error.localizedDescription
    }

    func presentComposerActionError(_ message: String, target: SessionPresentationTarget) {
        guard composerDrafts.admits(target) else { return }
        lastError = message
    }

    var mountedPresentationTarget: SessionPresentationTarget? {
        sessionPresentation.mountedTarget
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
        sessionPresentation.structureRevision(for: sessionID)
    }

    func sessionContextRevision(for sessionID: String) -> Int {
        sessionPresentation.contextRevision(for: sessionID)
    }

    func sessionResourceRevision(for sessionID: String) -> Int {
        sessionPresentation.resourceRevision(for: sessionID)
    }

    func settings(for target: SettingsTarget) -> JSONValue? {
        settingsTrust.settings(for: target)
    }

    func configuredDefaultModel(for target: SettingsTarget) -> ModelRef? {
        settingsTrust.configuredDefaultModel(for: target)
    }

    func providerCatalog(for target: ProviderCatalogTarget) -> ProviderCatalog? {
        providerAuth.catalog(for: target)
    }

    func preferredAvailableModel(for target: ProviderCatalogTarget) -> ModelRef? {
        providerAuth.preferredAvailableModel(for: target)
    }

    var visibleSessions: [SessionSummary] {
        SessionSummary.dashboardSessions(sessions).filter { !hiddenSessionIDs.contains($0.id) }
    }

    func dashboardActivity(for sessionID: String) -> DashboardSessionActivity {
        sessionCatalog.activity(for: sessionID)
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

    func presentConfigurationActionError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        lastError = error.localizedDescription
    }

    func start() async {
        await lifecycle.start()
    }

    @discardableResult
    func becameActive() -> Task<Void, Never>? {
        sceneAllowsCatalogRefresh = true
        return lifecycle.becameActive()
    }

    func enteredBackground() {
        sceneAllowsCatalogRefresh = false
        lifecycle.enteredBackground()
        catalogInvalidationGeneration &+= 1
        cancelCatalogRefresh()
    }

    func pair(_ invitation: PairingInvitation) async throws {
        try await lifecycle.pair(invitation)
    }

    private func admitsLifecycle(_ admission: GatewayLifecycleCoordinator.Admission) -> Bool {
        lifecycle.admits(admission)
    }

    private func requireLifecycle(_ admission: GatewayLifecycleCoordinator.Admission) throws {
        try lifecycle.require(admission)
    }

    private func requireConnection(_ admission: GatewayLifecycleCoordinator.Admission) throws {
        try lifecycle.requireConnection(admission)
    }

    private func invalidateProfileScopedLoads() {
        cancelCatalogRefresh()
        sessionCatalog.invalidateLoads()
        workspaceLoadGeneration &+= 1
        deviceLoadGeneration &+= 1
        legacyImportLoadGeneration &+= 1
    }

    private func clearGatewayProjection() {
        sessionCatalog.clear()
        sessionPresentation.clearProfile()
        pairedDevices.removeAll()
        legacyImportAvailable = false
        legacyImportedCount = 0
        workspace = nil
        hiddenSessionIDs.removeAll()
        providerAuth.clearProfile()
        settingsTrust.clearProfile()
        packageConfiguration.clearProfile()
        customModelConfiguration.clearProfile()
        composerDrafts.retireProfilePresentation()
        lastError = nil
        onboardingError = nil
        clearLiveConnectionProjection()
    }

    func switchGateway(_ profile: GatewayProfile) async {
        await lifecycle.switchGateway(profile)
    }

    func forgetCurrentGateway() async {
        let forgottenProfileID = profiles.selected?.id
        if await lifecycle.forgetCurrentGateway() {
            if let forgottenProfileID {
                composerDrafts.removeProfile(forgottenProfileID)
                await cache.remove(profileID: forgottenProfileID)
            }
            setupComplete = false
        }
    }

    func teardown() async {
        await lifecycle.teardown()
    }

    func restoreMountedPresentationAfterReconnect() async {
        _ = await sessionPresentation.reconnectMountedPresentation()
    }

    func refreshAll(
        settingsTarget: SettingsTarget = .global,
        providerTarget: ProviderCatalogTarget = .global
    ) async {
        async let sessionLoad = refreshSessions()
        async let providerLoad: Bool = refreshProviders(target: providerTarget)
        async let settingLoad: Bool = refreshSettings(target: settingsTarget)
        async let deviceLoad: Void = refreshDevices()
        _ = await (sessionLoad, providerLoad, settingLoad, deviceLoad)
    }

    @discardableResult
    func refreshSessions() async -> SessionCatalogRefreshOutcome {
        guard let key = currentCatalogLoadKey() else { return .retained }
        if let task = catalogRefreshTask, catalogRefreshKey == key {
            return await task.value
        }
        if catalogRefreshTask != nil { cancelCatalogRefresh() }
        return await startCatalogRefresh(key: key).value
    }

    private func currentCatalogLoadKey() -> SessionCatalogLoadKey? {
        guard sceneAllowsCatalogRefresh,
              let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
              let profileID = lifecycle.selectedProfileID else { return nil }
        return SessionCatalogLoadKey(
            profileID: profileID,
            lifecycleGeneration: admission.generation,
            connectionID: connectionID
        )
    }

    @discardableResult
    private func startCatalogRefresh(key: SessionCatalogLoadKey) -> Task<SessionCatalogRefreshOutcome, Never> {
        catalogRefreshRequestGeneration &+= 1
        let requestGeneration = catalogRefreshRequestGeneration
        let task = Task<SessionCatalogRefreshOutcome, Never> { @MainActor [weak self] in
            guard let self else { return SessionCatalogRefreshOutcome.retained }
            let outcome = await self.runCatalogRefreshLease(key: key, requestGeneration: requestGeneration)
            if self.catalogRefreshRequestGeneration == requestGeneration,
               self.catalogRefreshKey == key {
                let needsFollowUp = self.catalogDeferredFollowUpKey == key
                self.catalogDeferredFollowUpKey = nil
                self.catalogRefreshTask = nil
                self.catalogRefreshKey = nil
                if needsFollowUp, self.currentCatalogLoadKey() == key {
                    _ = self.startCatalogRefresh(key: key)
                }
            }
            return outcome
        }
        catalogRefreshKey = key
        catalogRefreshTask = task
        return task
    }

    private func runCatalogRefreshLease(
        key: SessionCatalogLoadKey,
        requestGeneration: Int
    ) async -> SessionCatalogRefreshOutcome {
        var outcome: SessionCatalogRefreshOutcome = .retained
        for traversal in 0..<2 {
            let observedInvalidation = catalogInvalidationGeneration
            outcome = await performCatalogTraversal(key: key, requestGeneration: requestGeneration)
            guard admitsCatalogRefresh(key: key, requestGeneration: requestGeneration) else { return .retained }
            if outcome == .transportFailure { return outcome }
            let dirtied = catalogInvalidationGeneration > observedInvalidation
            guard dirtied else { return outcome }
            if traversal == 1 {
                // Bound immediate catch-up under an event burst. Completion
                // hands one dirty bit to a new shared lease rather than
                // spinning forever inside this owner.
                catalogDeferredFollowUpKey = key
                return outcome
            }
        }
        return outcome
    }

    private func performCatalogTraversal(
        key: SessionCatalogLoadKey,
        requestGeneration: Int
    ) async -> SessionCatalogRefreshOutcome {
        struct Params: Encodable { let cursor: String?; let limit: Int; let scope: String }
        struct Response: Decodable {
            let sessions: [SessionSummary]
            let nextCursor: String?
            let listRevision: Int
        }

        for revisionAttempt in 0..<2 {
            let loadAdmission = sessionCatalog.beginLoad(key: key)
            var requestedContinuation = false
            do {
                let pageLimit = 500
                let maximumPages = 50
                let maximumItems = 25_000
                var all: [SessionSummary] = []
                var cursor: String?
                var seenCursors = Set<String>()
                var seenSessionIDs = Set<String>()
                var expectedRevision: Int?
                var revisionChanged = false
                var pageCount = 0
                repeat {
                    guard pageCount < maximumPages else { return .retained }
                    requestedContinuation = cursor != nil
                    let response: Response = try await client.request(
                        "session.list",
                        Params(cursor: cursor, limit: pageLimit, scope: "user")
                    )
                    pageCount += 1
                    guard admitsCatalogRefresh(key: key, requestGeneration: requestGeneration),
                          sessionCatalog.admits(loadAdmission, key: key) else { return .retained }
                    if let expectedRevision, expectedRevision != response.listRevision {
                        revisionChanged = true
                        break
                    }
                    expectedRevision = response.listRevision
                    guard response.sessions.count <= pageLimit,
                          all.count <= maximumItems - response.sessions.count,
                          response.sessions.allSatisfy({ seenSessionIDs.insert($0.id).inserted }) else {
                        return .retained
                    }
                    all.append(contentsOf: response.sessions)
                    cursor = response.nextCursor
                    if let cursor, !seenCursors.insert(cursor).inserted { return .retained }
                } while cursor != nil

                if revisionChanged {
                    if revisionAttempt == 0 { continue }
                    return .retained
                }
                guard sessionCatalog.publishAuthoritative(all, admission: loadAdmission) else { return .retained }
                reconcileSelection()
                scheduleCacheCheckpoint()
                return .published
            } catch is CancellationError {
                return .retained
            } catch let failure as GatewayFailure
                where requestedContinuation && failure.code == "invalid_request" && revisionAttempt == 0 {
                guard admitsCatalogRefresh(key: key, requestGeneration: requestGeneration),
                      sessionCatalog.admits(loadAdmission, key: key) else { return .retained }
                continue
            } catch {
                guard admitsCatalogRefresh(key: key, requestGeneration: requestGeneration),
                      sessionCatalog.admits(loadAdmission, key: key) else { return .retained }
                return Self.catalogFailureOutcome(error)
            }
        }
        return .retained
    }

    private func admitsCatalogRefresh(
        key: SessionCatalogLoadKey,
        requestGeneration: Int
    ) -> Bool {
        guard catalogRefreshRequestGeneration == requestGeneration,
              catalogRefreshKey == key,
              let admission = lifecycle.admission else { return false }
        return admission.generation == key.lifecycleGeneration
            && admission.connectionID == key.connectionID
            && lifecycle.selectedProfileID == key.profileID
    }

    private static func catalogFailureOutcome(_ error: Error) -> SessionCatalogRefreshOutcome {
        if error is CancellationError { return .retained }
        if let failure = error as? GatewayFailure,
           ["disconnected", "closed", "replaced", "timeout"].contains(failure.code) {
            return .transportFailure
        }
        if error is URLError { return .transportFailure }
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain { return .transportFailure }
        return .retained
    }

    private func cancelCatalogRefresh() {
        catalogRefreshRequestGeneration &+= 1
        catalogDeferredFollowUpKey = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        catalogRefreshKey = nil
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
        let response: Response = try await mutationExecutor.perform(method: "device.revoke", commandID: commandID) {
            try await client.request("device.revoke", params)
        }
        if response.revoked {
            pairedDevices.removeAll { $0.id == id }
            if let profile = profiles.selected, profile.deviceId == id,
               await lifecycle.forget(profile: profile) {
                composerDrafts.removeProfile(profile.id)
                await cache.remove(profileID: profile.id)
                setupComplete = false
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
        let response: Response = try await mutationExecutor.perform(method: "legacy.import", commandID: commandID) {
            try await client.request("legacy.import", params, timeout: .seconds(600))
        }
        legacyImportedCount += response.imported
        postNotice("Imported \(response.imported) legacy session\(response.imported == 1 ? "" : "s"); skipped \(response.skipped).")
        await refreshSessions()
    }

    func importSession(from url: URL, cwd: String) async throws -> SessionNavigationRoute {
        let imported = try await sessionImports.importSession(from: url, cwd: cwd)
        await refreshSessions()
        try sessionImports.requireCurrent(imported)
        return SessionNavigationRoute(
            sessionID: imported.sessionID,
            editorText: nil,
            gatewayProfileID: imported.profileID,
            gatewayLifecycleGeneration: imported.lifecycleGeneration
        )
    }

    func ownsNavigationRoute(_ route: SessionNavigationRoute) -> Bool {
        guard let gatewayProfileID = route.gatewayProfileID else { return true }
        guard profiles.selected?.id == gatewayProfileID,
              let generation = route.gatewayLifecycleGeneration else { return false }
        return lifecycle.admits(.init(generation: generation, connectionID: nil))
    }

    func createSession(cwd: String) async throws -> SessionNavigationRoute {
        guard let admission = lifecycle.generationAdmission,
              let profileID = lifecycle.selectedProfileID else { throw CancellationError() }
        let sessionID = try await sessionMutations.createSession(cwd: cwd)
        try requireLifecycle(admission)
        guard lifecycle.selectedProfileID == profileID else { throw CancellationError() }
        defaultWorkspace = cwd
        UserDefaults.standard.set(cwd, forKey: "defaultWorkspace.v1")
        return SessionNavigationRoute(
            sessionID: sessionID,
            editorText: nil,
            gatewayProfileID: profileID,
            gatewayLifecycleGeneration: admission.generation
        )
    }

    /// Starts a new mounted chat presentation. Unlike reconnect synchronization,
    /// this always installs a fresh authoritative bounded tail and never carries
    /// an explicitly paged prefix across navigation lifetimes.
    func openSessionPresentation(
        _ id: String,
        composerScope suppliedScope: ComposerDraftScope? = nil
    ) async throws -> Int {
        guard let admission = lifecycle.generationAdmission,
              let profileID = lifecycle.selectedProfileID else { throw CancellationError() }
        let scope = suppliedScope ?? composerDrafts.prepareDraft(
            profileID: profileID,
            sessionID: id,
            initialText: nil
        )
        guard scope.profileID == profileID, scope.sessionID == id else { throw CancellationError() }
        #if HOSTED_TEST
        let hostedAdmission = hostedSessionOpenAdmissionOverride ?? true
        hostedSessionOpenAdmissionOverride = nil
        #else
        let hostedAdmission = true
        #endif
        return try await composerDrafts.openMountedPresentation(
            scope: scope,
            lifecycleGeneration: admission.generation,
            open: { try await sessionPresentation.open(id) },
            finalAdmission: { _ in
                try requireLifecycle(admission)
                guard hostedAdmission,
                      lifecycle.selectedProfileID == profileID else { throw CancellationError() }
            },
            revokePresentation: sessionPresentation.revokeIntake,
            closePresentation: sessionPresentation.close
        )
    }

    func closeSessionPresentation(_ id: String, generation: Int) async {
        let target = SessionPresentationTarget(sessionID: id, generation: generation)
        composerDrafts.revoke(target)
        await sessionPresentation.close(target)
    }

    func loadEarlierTranscript(sessionID: String, presentationGeneration: Int) async {
        await sessionPresentation.loadEarlier(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration
        )
    }

    func discardLoadedTranscriptHistory(
        sessionID: String,
        presentationGeneration: Int
    ) {
        sessionPresentation.discardLoadedTranscriptHistory(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration
        )
    }

    private func invalidateSessionConnectionOwnership() {
        chatMedia.removeAll()
        sessionPresentation.retireConnection()
    }

    static func ownsPresentation(
        mountedGeneration: Int?,
        requestedGeneration: Int
    ) -> Bool {
        SessionPresentationStore.ownsPresentation(
            mountedGeneration: mountedGeneration,
            requestedGeneration: requestedGeneration
        )
    }

    static func admitsPresentationIntake(
        mountedGeneration: Int?,
        requestedGeneration: Int,
        isRevoked: Bool
    ) -> Bool {
        SessionPresentationStore.admitsPresentationIntake(
            mountedGeneration: mountedGeneration,
            requestedGeneration: requestedGeneration,
            isRevoked: isRevoked
        )
    }

    static func ownsSubscription(
        sessionID: String,
        subscribedSessionID: String?,
        installedToken: String?,
        requestedToken: String
    ) -> Bool {
        SessionPresentationStore.ownsSubscription(
            sessionID: sessionID,
            subscribedSessionID: subscribedSessionID,
            installedToken: installedToken,
            requestedToken: requestedToken
        )
    }

    static func shouldClearSubscription(
        installedToken: String?,
        closingToken: String,
        gatewayClosed: Bool
    ) -> Bool {
        SessionPresentationStore.shouldClearSubscription(
            installedToken: installedToken,
            closingToken: closingToken,
            gatewayClosed: gatewayClosed
        )
    }

    func sendSharedContent(
        _ text: String,
        target: SessionPresentationTarget
    ) async throws {
        guard ownsPresentation(target) else { throw CancellationError() }
        try await sessionMutations.prompt(
            text,
            sessionID: target.sessionID,
            uploadIDs: [],
            behavior: nil
        )
    }

    func sendComposer(
        target: SessionPresentationTarget,
        behavior: String? = nil
    ) async throws {
        try await composerDrafts.send(target: target, behavior: behavior)
    }

    func abort(sessionID: String, kind: String = "agent") async {
        do { try await sessionMutations.abort(sessionID: sessionID, kind: kind) }
        catch { surface(error) }
    }

    func clearQueue(sessionID: String) async throws -> SessionSnapshot.QueuedMessages {
        let cleared = try await sessionMutations.clearQueue(sessionID: sessionID)
        sessionPresentation.clearConfirmedQueue(sessionID: sessionID)
        return cleared
    }

    func replaceQueue(
        sessionID: String,
        expectedRevision: Int,
        items: [SessionSnapshot.QueuedMessage]
    ) async throws {
        try await sessionMutations.replaceQueue(
            sessionID: sessionID,
            expectedRevision: expectedRevision,
            items: items
        )
    }

    func executeBash(_ command: String, sessionID: String, excludeFromContext: Bool = false) async throws {
        try await sessionMutations.executeBash(
            command,
            sessionID: sessionID,
            excludeFromContext: excludeFromContext
        )
    }

    func setModel(_ model: ModelRef, sessionID: String) async throws {
        try await sessionMutations.setModel(model, sessionID: sessionID)
    }

    func setThinking(_ level: String, sessionID: String) async throws {
        try await sessionMutations.setThinking(level, sessionID: sessionID)
    }

    func renameSession(_ sessionID: String, name: String) async throws {
        try await sessionMutations.rename(sessionID, name: name)
    }

    func compact(sessionID: String, instructions: String? = nil) async throws {
        try await sessionMutations.compact(sessionID: sessionID, instructions: instructions)
    }

    func setTools(_ tools: [String], sessionID: String) async throws {
        try await sessionMutations.setTools(tools, sessionID: sessionID)
    }

    func fork(
        sessionID: String,
        entryID: String,
        position: String = "before"
    ) async throws -> SessionNavigationRoute {
        let outcome = try await sessionMutations.fork(
            sessionID: sessionID,
            entryID: entryID,
            position: position
        )
        await refreshSessions()
        return SessionNavigationRoute(
            sessionID: outcome.sessionID,
            editorText: outcome.selectedText
        )
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
        let editorText = try await sessionMutations.navigate(
            sessionID: sessionID,
            entryID: entryID,
            summarize: summarize,
            instructions: instructions,
            replaceInstructions: replaceInstructions,
            label: label
        )
        if let editorText,
           let editorTarget,
           ownsPresentation(editorTarget) {
            composerDrafts.publishEditorRequest(
                ComposerEditorRequest(
                    sessionID: sessionID,
                    presentationGeneration: editorTarget.generation,
                    revision: Int(Date.now.timeIntervalSince1970 * 1_000),
                    action: .set,
                    text: editorText,
                    fullText: editorText
                ),
                target: editorTarget
            )
        }
        await loadTree(sessionID: sessionID)
        return editorText
    }

    func setLabel(sessionID: String, entryID: String, label: String?) async throws {
        try await sessionMutations.setLabel(
            sessionID: sessionID,
            entryID: entryID,
            label: label
        )
        await loadTree(sessionID: sessionID)
    }

    func exportSession(sessionID: String, format: String) async throws -> URL {
        guard let subscriptionToken = sessionPresentation.installedSubscriptionToken(for: sessionID) else {
            throw GatewayFailure(code: "sync_failed", message: "Open the session before exporting it.", retryable: true, details: nil)
        }
        struct Params: Codable { let sessionId, format: String }
        struct Response: Decodable { let blobId, name, mimeType: String }
        let response: Response = try await client.request("session.export", Params(sessionId: sessionID, format: format), timeout: .seconds(120))
        guard sessionPresentation.ownsInstalledSubscription(
            sessionID: sessionID,
            token: subscriptionToken
        ) else { throw CancellationError() }
        try Task.checkCancellation()
        let data = try await client.blob(
            id: response.blobId,
            maximumBytes: SessionExportArtifactPolicy.maximumEncodedBytes
        ).0
        guard sessionPresentation.ownsInstalledSubscription(
            sessionID: sessionID,
            token: subscriptionToken
        ) else { throw CancellationError() }
        try Task.checkCancellation()
        let artifact = try await exportArtifacts.write(data, suggestedName: response.name)
        guard !Task.isCancelled, sessionPresentation.ownsInstalledSubscription(
            sessionID: sessionID,
            token: subscriptionToken
        ) else {
            await exportArtifacts.discard(artifact)
            throw CancellationError()
        }
        return artifact
    }

    func discardExportArtifact(_ artifact: URL) async {
        await exportArtifacts.discard(artifact)
    }

    func deleteSession(_ id: String) async throws {
        await sessionPresentation.closeSubscriptionIfInstalled(sessionID: id)
        try await sessionMutations.delete(sessionID: id)
        sessionPresentation.remove(sessionID: id)
        if let profileID = lifecycle.selectedProfileID {
            composerDrafts.removeSession(profileID: profileID, sessionID: id)
        }
        sessionCatalog.remove(id)
        scheduleCacheCheckpoint()
    }

    func loadContext(sessionID: String) async {
        await sessionPresentation.loadContext(sessionID: sessionID)
    }

    func loadTree(sessionID: String) async {
        await sessionPresentation.loadTree(sessionID: sessionID)
    }

    func loadCommands(sessionID: String) async {
        await sessionPresentation.loadCommands(sessionID: sessionID)
    }

    func loadResources(sessionID: String) async {
        await sessionPresentation.loadResources(sessionID: sessionID)
    }

    func reloadResources(sessionID: String) async throws {
        try await sessionMutations.reloadResources(sessionID: sessionID)
    }

    func archive(_ id: String) {
        // Kept only for migration of previous local-hidden state. New UI uses
        // canonical session deletion and labels it accurately.
        hiddenSessionIDs.insert(id)
        persistHidden()
        sessionPresentation.remove(sessionID: id)
    }

    func upload(
        name: String,
        mimeType: String,
        data: Data,
        target: SessionPresentationTarget
    ) async throws {
        try await composerDrafts.upload(
            name: name,
            mimeType: mimeType,
            data: data,
            target: target
        )
    }

    @discardableResult
    func refreshProviders(target: ProviderCatalogTarget) async -> Bool {
        await providerAuth.refreshCatalog(target: target)
    }

    func beginAuth(providerID: String, authType: String, target: ProviderCatalogTarget) async throws {
        try await providerAuth.beginAuth(providerID: providerID, authType: authType, target: target)
    }

    func answerAuth(_ value: String) async throws {
        try await providerAuth.answerAuth(value)
    }

    func cancelAuth(operationID: String? = nil) async {
        await providerAuth.cancelAuth(operationID: operationID)
    }

    func refreshModelCatalog(target: ProviderCatalogTarget, force: Bool = true) async throws {
        try await providerAuth.refreshModelCatalog(target: target, force: force)
    }

    func logout(providerID: String, target: ProviderCatalogTarget) async throws {
        try await providerAuth.logout(providerID: providerID, target: target)
    }

    @discardableResult
    func refreshSettings(target: SettingsTarget) async -> Bool {
        await settingsTrust.refreshSettings(target: target)
    }

    func updateSettings(_ patch: JSONValue, target: SettingsTarget) async throws {
        try await settingsTrust.updateSettings(patch, target: target)
    }

    func inspectTrust(target: TrustTarget) async throws -> JSONValue {
        try await settingsTrust.inspectTrust(target: target)
    }

    func setTrust(target: TrustTarget, decision: Bool?) async throws -> JSONValue {
        try await settingsTrust.setTrust(target: target, decision: decision)
    }

    func packageInventory(for target: PackageConfigurationTarget) -> PackageInventory? {
        packageConfiguration.inventory(for: target)
    }

    func packageUpdates(for target: PackageConfigurationTarget) -> [PackageUpdate] {
        packageConfiguration.updates(for: target)
    }

    @discardableResult
    func loadPackages(target: PackageConfigurationTarget) async -> Bool {
        await packageConfiguration.load(target: target)
    }

    @discardableResult
    func checkPackageUpdates(target: PackageConfigurationTarget) async -> Bool {
        await packageConfiguration.checkUpdates(target: target)
    }

    func mutatePackage(
        action: PackageMutationAction,
        source: String?,
        local: Bool,
        target: PackageConfigurationTarget
    ) async throws {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        do {
            try await packageConfiguration.mutate(action, source: source, local: local, target: target)
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
        try requireLifecycle(admission)
    }

    func customModels(for target: CustomModelTarget) -> JSONValue? {
        customModelConfiguration.models(for: target)
    }

    @discardableResult
    func loadCustomModels(target: CustomModelTarget) async -> Bool {
        await customModelConfiguration.load(target: target)
    }

    func replaceCustomModelsAndRestart(
        _ document: JSONValue,
        target: CustomModelTarget
    ) async throws {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        try requireLifecycle(admission)
        do {
            try await customModelConfiguration.replace(document, target: target)
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
        try requireLifecycle(admission)
        do {
            try await restartGateway(admission: admission)
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
    }

    nonisolated static func supportsSafeGatewayRestart(capabilities: [String]) -> Bool {
        capabilities.contains("restart-drain.v1")
    }

    func restartGateway() async throws {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        do {
            try await restartGateway(admission: admission)
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
    }

    func requestGatewayRestart() async {
        do { try await restartGateway() }
        catch { surface(error) }
    }

    private func restartGateway(
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws {
        try requireLifecycle(admission)
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
        let response: Response
        do {
            response = try await mutationExecutor.perform(method: "gateway.restart", commandID: commandID) {
                try await client.request("gateway.restart", Params(commandId: commandID))
            }
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
        try requireLifecycle(admission)
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
        let workspaceGeneration = workspaceLoadGeneration
        let commandID = uuidSource.next().uuidString
        let params = Params(parent: parent, name: name, commandId: commandID)
        let response: Response = try await mutationExecutor.perform(method: "filesystem.mkdir", commandID: commandID) {
            try await client.request("filesystem.mkdir", params)
        }
        if workspaceLoadGeneration == workspaceGeneration {
            try await loadWorkspace(path: parent)
        }
        defaultWorkspace = response.path
    }

    func answerInteraction(
        _ interaction: ExtensionInteraction,
        sessionID: String,
        value: JSONValue?,
        cancelled: Bool
    ) async throws {
        try await sessionMutations.answerInteraction(
            interactionID: interaction.id,
            sessionID: sessionID,
            value: value,
            cancelled: cancelled
        )
    }

    func beginTerminalPresentation(sessionID: String) -> TerminalPresentationTarget {
        terminal.beginPresentation(sessionID: sessionID)
    }

    func beginTerminalIntent(
        for target: TerminalPresentationTarget
    ) -> TerminalPresentationIntent? {
        terminal.beginIntent(for: target)
    }

    func closeTerminalPresentation(_ target: TerminalPresentationTarget) {
        terminal.closePresentation(target)
    }

    func ownsTerminalIntent(_ intent: TerminalPresentationIntent) -> Bool {
        terminal.owns(intent)
    }

    func terminalReplay(for terminalID: String) -> TerminalReplayProjection {
        terminal.replay(for: terminalID)
    }

    func terminalHasExited(_ terminalID: String) -> Bool {
        terminal.hasExited(terminalID)
    }

    func listTerminals(intent: TerminalPresentationIntent) async throws -> [TerminalSummary] {
        try await terminal.list(intent: intent)
    }

    func openTerminal(
        intent: TerminalPresentationIntent,
        columns: Int,
        rows: Int
    ) async throws -> TerminalSummary {
        try await terminal.open(intent: intent, columns: columns, rows: rows)
    }

    func attachTerminal(
        _ id: String,
        after: Int,
        intent: TerminalPresentationIntent
    ) async throws -> TerminalSummary {
        try await terminal.attach(id, after: after, intent: intent)
    }

    func writeTerminal(
        _ id: String,
        data: String,
        intent: TerminalPresentationIntent
    ) async throws {
        try await terminal.write(id, data: data, intent: intent)
    }

    func resizeTerminal(
        _ id: String,
        columns: Int,
        rows: Int,
        intent: TerminalPresentationIntent
    ) async throws {
        try await terminal.resize(
            id,
            columns: columns,
            rows: rows,
            intent: intent
        )
    }

    func terminateTerminal(_ id: String, intent: TerminalPresentationIntent) async throws {
        try await terminal.terminate(id, intent: intent)
    }

    func handle(_ event: GatewayEvent) async {
        await handle(event, connectionID: nil)
    }

    private func handle(_ event: GatewayEvent, connectionID: Int?) async {
        guard lifecycle.admitsEvent(connectionID: connectionID) else { return }
        if event.topic.hasPrefix("session."), event.topic != "session.listChanged", event.topic != "session.summary" {
            await sessionPresentation.admit(event)
            return
        }
        await handleDeliveredEvent(event, connectionID: connectionID)
    }

    private func handleDeliveredEvent(_ event: GatewayEvent, connectionID: Int?) async {
        switch event.topic {
        case "transport.disconnected", "system.stopping":
            lifecycle.noteDisconnected(connectionID: connectionID)
            invalidateSessionConnectionOwnership()
            sessionCatalog.markDisconnected()
            lifecycle.requestReconnect()
        case "transport.resyncRequired":
            await sessionPresentation.handleResyncRequired(sessionID: event.sessionId)
        case "session.summary":
            if case .sessionSummary(let update) = event.preparation { apply(update) }
        case "session.listChanged":
            scheduleSessionListRefresh()
        case "auth.prompt":
            providerAuth.handlePrompt(event.payload)
        case "auth.event":
            providerAuth.handleEvent(event.payload)
        case "auth.completed":
            await providerAuth.handleCompletion(event.payload)
        case "settings.changed":
            settingsTrust.noteSettingsChanged()
        case "trust.changed":
            settingsTrust.noteTrustChanged()
        case "providers.changed":
            providerAuth.noteProvidersChanged()
        case "packages.changed":
            packageConfiguration.notePackagesChanged()
        case "models.customChanged":
            customModelConfiguration.noteCustomModelsChanged()
        case "packages.progress", "packages.completed":
            postNotice(
                event.topic == "packages.completed" ? "Package operation completed" : "Updating agent package…",
                replacing: .packageProgress
            )
        case "terminal.output", "terminal.exit":
            guard let connectionID = gatewayConnectionID,
                  case .terminalEvent(let terminalEvent) = event.preparation else { break }
            terminal.admit(
                terminalEvent,
                connectionID: connectionID,
                exitedAt: GatewayTimestamp.string(from: .now)
            )
        default:
            break
        }
    }

    static func installingSnapshot(
        current: SessionSnapshot?,
        authoritative: SessionSnapshot,
        mode: SessionSnapshotInstallMode
    ) -> SessionSnapshot {
        SessionPresentationStore.installingSnapshot(
            current: current,
            authoritative: authoritative,
            mode: mode
        )
    }

    static func mergingVisibleTranscript(
        current: SessionSnapshot,
        authoritative: SessionSnapshot
    ) -> SessionSnapshot {
        SessionPresentationStore.mergingVisibleTranscript(
            current: current,
            authoritative: authoritative
        )
    }

    private func apply(_ update: SessionSummaryUpdate) {
        switch sessionCatalog.apply(update) {
        case .stale:
            return
        case .unknownSession:
            scheduleSessionListRefresh()
        case .updated:
            scheduleCacheCheckpoint()
        }
    }

    private func scheduleSessionListRefresh() {
        catalogInvalidationGeneration &+= 1
        guard catalogRefreshTask == nil,
              let key = currentCatalogLoadKey() else { return }
        _ = startCatalogRefresh(key: key)
    }

    private func clearLiveConnectionProjection() {
        noticeStore.removeAll()
        sessionCatalog.markDisconnected()
    }

    private func reconcileSelection() {
        defaultWorkspace = UserDefaults.standard.string(forKey: "defaultWorkspace.v1")
        loadHidden()
    }

    private var hiddenKey: String { "hiddenSessions.\(profiles.selected?.id ?? "none")" }
    private func loadHidden() { hiddenSessionIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
    private func persistHidden() { UserDefaults.standard.set(Array(hiddenSessionIDs), forKey: hiddenKey) }

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

    private func loadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        let value = await cache.load(profileID: profileID)
        guard admitsLifecycle(admission), profiles.selected?.id == profileID else { return }
        sessionCatalog.installCached(value.sessions)
        reconcileSelection()
    }

    private func scheduleCacheCheckpoint() {
        guard let profileID = profiles.selected?.id else { return }
        cacheCheckpointGeneration &+= 1
        pendingCacheCheckpoint = CacheCheckpoint(
            profileID: profileID,
            generation: cacheCheckpointGeneration,
            sessions: sessions,
            snapshots: sessionPresentation.disposableCacheSnapshot.map { [$0] } ?? []
        )
        guard cacheCheckpointTask == nil else { return }
        cacheCheckpointTaskGeneration &+= 1
        let taskGeneration = cacheCheckpointTaskGeneration
        cacheCheckpointTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let checkpoint = self.pendingCacheCheckpoint {
                self.pendingCacheCheckpoint = nil
                await self.cache.save(
                    profileID: checkpoint.profileID,
                    generation: checkpoint.generation,
                    sessions: checkpoint.sessions,
                    snapshots: checkpoint.snapshots
                )
            }
            if self.cacheCheckpointTaskGeneration == taskGeneration {
                self.cacheCheckpointTask = nil
            }
        }
    }

    private func cancelCacheCheckpoints() {
        cacheCheckpointTaskGeneration &+= 1
        pendingCacheCheckpoint = nil
        cacheCheckpointTask?.cancel()
        cacheCheckpointTask = nil
    }

}

extension AppModel: SessionPresentationStoreDelegate {
    func sessionPresentationStoreDidRequestCatalogRefresh() {
        scheduleSessionListRefresh()
    }

    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationTarget,
        action: SessionEditorAction,
        text: String,
        fullText: String,
        revision: Int
    ) {
        guard ownsPresentation(target) else { return }
        composerDrafts.publishEditorRequest(
            ComposerEditorRequest(
                sessionID: target.sessionID,
                presentationGeneration: target.generation,
                revision: revision,
                action: action,
                text: text,
                fullText: fullText
            ),
            target: target
        )
    }

    func sessionPresentationStoreDidOpen(_ target: SessionPresentationTarget) {
        _ = composerDrafts.mountPreparedPresentation(target)
        Task { [weak self] in
            guard let self else { return }
            async let providerRefresh: Bool = self.refreshProviders(target: .session(id: target.sessionID))
            async let commandRefresh: Void = self.loadCommands(sessionID: target.sessionID)
            _ = await (providerRefresh, commandRefresh)
        }
    }

    func sessionPresentationStorePostNotice(_ message: String, replacing key: GlobalNoticeKey?) {
        postNotice(message, replacing: key)
    }

    func sessionPresentationStoreRemoveNotice(_ key: GlobalNoticeKey) {
        removeNotice(key)
    }

    func sessionPresentationStoreSurface(_ error: Error) {
        surface(error)
    }

    func sessionPresentationStoreCheckpointCache() {
        scheduleCacheCheckpoint()
    }
}

extension AppModel: SettingsTrustCoordinatorDelegate {
    func settingsTrustCoordinatorSurface(_ error: Error) {
        surface(error)
    }
}

extension AppModel: ProviderAuthCoordinatorDelegate {
    func providerAuthCoordinatorSurface(_ error: Error) {
        surface(error)
    }

    func providerAuthCoordinatorSetCompletionError(_ message: String?) {
        lastError = message
    }
}

extension AppModel: PackageConfigurationCoordinatorDelegate {
    func packageConfigurationCoordinatorSurface(_ error: Error) {
        surface(error)
    }
}

extension AppModel: CustomModelConfigurationCoordinatorDelegate {
    func customModelConfigurationCoordinatorSurface(_ error: Error) {
        surface(error)
    }
}

extension AppModel: GatewayLifecycleProjectionDelegate {
    func lifecycleLoadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        await loadCache(profileID: profileID, admission: admission)
    }

    func lifecycleInvalidateSessionConnectionOwnership() {
        invalidateSessionConnectionOwnership()
    }

    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {
        guard admitsLifecycle(admission) else { return }
        await refreshAll()
    }

    func lifecycleRestoreMountedPresentation(
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        guard admitsLifecycle(admission) else { return }
        await restoreMountedPresentationAfterReconnect()
    }

    func lifecycleReattachTerminals(
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        await terminal.reattach(admission: admission)
    }

    func lifecycleReconcileForeground(
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws {
        try await client.ensureResponsive()
        try requireLifecycle(admission)
        async let catalog = refreshSessions()
        await sessionPresentation.reconnectMountedPresentation()
        await terminal.reattach(admission: admission)
        _ = await catalog
        try requireLifecycle(admission)
    }

    func lifecycleRetireProjection(final: Bool) async {
        let catalog = catalogRefreshTask
        let cacheCheckpoint = cacheCheckpointTask
        let events = final ? eventTask : nil
        let terminalRetirement = terminal.beginRetirement()
        cancelCatalogRefresh()
        cancelCacheCheckpoints()
        if final {
            events?.cancel()
            eventTask = nil
        }

        invalidateProfileScopedLoads()
        invalidateSessionConnectionOwnership()
        clearGatewayProjection()

        _ = await catalog?.value
        await cacheCheckpoint?.value
        await terminal.finishRetirement(terminalRetirement)
        await events?.value
    }

    func lifecycleSurface(_ error: Error) {
        surface(error)
    }
}
