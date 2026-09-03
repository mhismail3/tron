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

private struct GatewayUpdateAcknowledgement: Codable {
    let accepted: Bool
    let commandId: String

    func require(commandID: String) throws {
        guard accepted, commandId == commandID else {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The Gateway update acknowledgement did not match the submitted command.",
                retryable: false,
                details: nil
            )
        }
    }
}

enum PushNavigationConnectionPolicy {
    static let readinessDeadline: Duration = .seconds(15)
}

enum SessionMountedAuthorityPolicy {
    static func admits(
        ownsPresentation: Bool,
        hasInstalledSubscription: Bool,
        snapshotSessionID: String?,
        targetSessionID: String
    ) -> Bool {
        ownsPresentation
            && hasInstalledSubscription
            && snapshotSessionID == targetSessionID
    }
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
        let initialModel: ModelRef?
        fileprivate let gatewayProfileID: String?
        fileprivate let gatewayLifecycleGeneration: Int?
        var id: String { gatewayProfileID.map { "\($0):\(sessionID)" } ?? sessionID }

        init(
            sessionID: String,
            editorText: String?,
            initialModel: ModelRef? = nil,
            gatewayProfileID: String? = nil,
            gatewayLifecycleGeneration: Int? = nil
        ) {
            self.sessionID = sessionID
            self.editorText = editorText
            self.initialModel = initialModel
            self.gatewayProfileID = gatewayProfileID
            self.gatewayLifecycleGeneration = gatewayLifecycleGeneration
        }

        func withInitialModel(_ model: ModelRef?) -> SessionNavigationRoute {
            SessionNavigationRoute(
                sessionID: sessionID,
                editorText: editorText,
                initialModel: model,
                gatewayProfileID: gatewayProfileID,
                gatewayLifecycleGeneration: gatewayLifecycleGeneration
            )
        }
    }

    struct PushNavigationRequest: Identifiable, Equatable {
        let id: Int
        let tap: PushNotificationTap
    }

    typealias SessionPresentationTarget = SessionPresentationIdentity

    typealias SessionOpenResponse = GatewaySessionOpenResponse
    typealias PairingCommit = GatewayPairingCommit
    typealias ProfileTokenLookup = GatewayProfileTokenLookup

    private struct CacheCheckpoint: Sendable {
        let profileID: String
        let generation: Int
        let sessions: [SessionSummary]
    }

    private struct DashboardMutationOwner: Sendable {
        let profileID: String
        let lifecycleGeneration: Int
        let connectionID: Int
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
    let extensionInteractionDrafts: ExtensionInteractionDraftStore
    let gatewayDiagnostics: GatewayDiagnosticsService
    let workspaceInspection: WorkspaceInspectionService
    private var iosClientDiagnostics = IOSClientDiagnosticBuffer()
    /// Bounded, content-free causal trace for intermittent chat viewport and
    /// opening failures. It is merged into Logs on demand and never persisted.
    let chatInteractionTrace = ChatInteractionTrace()
    let chatMedia: ChatMediaLoader
    private let chatMediaMemoryPressureObserver: ChatMediaMemoryPressureObserver

    var connectionState: ConnectionState { lifecycle.connectionState }
    /// False only while the first launch credential/connection decision is
    /// unresolved. The UI must not infer "unpaired" from the temporary default.
    var hasResolvedLaunchState: Bool { lifecycle.hasResolvedLaunchState }
    var gatewayInfo: GatewayInfo? { lifecycle.gatewayInfo }
    private var gatewayConnectionID: Int? { lifecycle.connectionID }
    private var sessionCatalog = SessionCatalogCoordinator()
    private let dashboardConnections: DashboardGatewayConnectionPool
    let automationCatalog: AutomationCatalogCoordinator
    private var dashboardSessionsByProfile: [String: [SessionSummary]] = [:]
    private var dashboardStatesByProfile: [String: DashboardServerConnectionState] = [:]
    private var dashboardCacheLoadGeneration = 0
    var sessions: [SessionSummary] {
        get { sessionCatalog.sessions }
        set {
            sessionCatalog.replaceForFacade(newValue)
            installSelectedDashboardCatalog()
        }
    }
    private let sessionPresentation: SessionPresentationStore
    var settingsInvalidationGeneration: Int { settingsTrust.settingsInvalidationGeneration }
    var providerInvalidationGeneration: Int { providerAuth.invalidationGeneration }
    var packageInvalidationGeneration: Int { packageConfiguration.invalidationGeneration }
    var customModelInvalidationGeneration: Int { customModelConfiguration.invalidationGeneration }
    var trustRevision: Int { settingsTrust.trustRevision }
    var pairedDevices: [PairedDevice] = []
    let notificationInbox = NotificationInboxCoordinator()
    var pushNotificationReadiness: PushReadiness = .unavailable
    var pushRegistrationDiagnostic: PushRegistrationDiagnostic = .idle
    private(set) var pushNavigationRequest: PushNavigationRequest?
    /// Lease-scoped invalidation for a mounted read-only subagent transcript.
    /// This does not participate in the parent session event cursor.
    private(set) var processTranscriptInvalidation: ProcessTranscriptChanged?
    var actionablePushNavigationRequest: PushNavigationRequest? {
        guard didStart, sceneAllowsCatalogRefresh, pushNavigationActivationReady else { return nil }
        return pushNavigationRequest
    }
    private var pushNavigationSequence = 0
    private var pushNavigationActivationGeneration = 0
    private var pushNavigationActivationReady = false
    private var didStart = false
    /// GatewayProfileStore owns transactional persistence; this revision makes
    /// profile metadata changes observable to SwiftUI without duplicating it.
    private(set) var profileRevision = 0
    private(set) var dashboardPresentationRevision = 0
    var legacyImportAvailable = false
    var legacyImportedCount = 0
    var workspace: WorkspaceListing?
    var defaultWorkspace: String?
    var authPrompt: AuthPromptState? { providerAuth.prompt }
    var authEvent: AuthEventState? { providerAuth.event }
    let noticeCenter: InAppNoticeCenter
    private(set) var logsPresentationRequested = false
    var visibleNotices: [InAppNoticeCenter.Notice] { noticeCenter.visibleNotices }
    var context: JSONValue? { sessionPresentation.context }
    var sessionTree: [SessionTreeNode] { sessionPresentation.sessionTree }
    var loadingEarlierTranscript: Bool { sessionPresentation.loadingEarlierTranscript }
    var transcriptLoadState: SessionTranscriptLoadState { sessionPresentation.transcriptLoadState }
    /// Foreground reconciliation is an aggregate install, not a live insertion
    /// stream; mounted chats use this fact to suppress entrance replay. The
    /// generation remains stable until its first aggregate projection installs,
    /// even if the network task finishes before projection preparation does.
    private(set) var isReconcilingForeground = false
    private(set) var foregroundReconciliationGeneration = 0
    private var reconciliationAggregateAdmission: GatewayLifecycleCoordinator.Admission?
    /// Advances only after an admitted Gateway projection is ready for bounded
    /// on-demand diagnostics such as Logs. Views key refresh work to completion,
    /// never raw scene activation, a transient connected state, or reconciliation start.
    private(set) var diagnosticsReadinessGeneration = 0
    private(set) var diagnosticsAreReady = false
    var commands: [CommandInfo] { sessionPresentation.commands }
    var commandCatalogTarget: SessionPresentationIdentity? { sessionPresentation.commandCatalogTarget }
    var resources: JSONValue? { sessionPresentation.resources }
    /// Keeps the root setup sheet from reacting to the transient connection
    /// state used while the Connections sheet adds a secondary server.
    var isAddingServer = false
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
    private var extensionEditorSyncTasks: [SessionPresentationIdentity: Task<Void, Never>] = [:]
    private var extensionEditorPendingText: [SessionPresentationIdentity: String] = [:]
    private var extensionEditorPendingRevisions: [SessionPresentationIdentity: Int] = [:]
    private var extensionEditorSyncGenerations: [SessionPresentationIdentity: Int] = [:]
    private var extensionEditorOperationReceipts: [SessionPresentationIdentity: [String]] = [:]
    private var deviceLoadGeneration = 0
    private var legacyImportLoadGeneration = 0
    private var catalogRefreshTask: Task<SessionCatalogRefreshOutcome, Never>?
    private var catalogRefreshKey: SessionCatalogLoadKey?
    private var catalogRefreshRequestGeneration = 0
    private var catalogInvalidationGeneration = 0
    private var catalogSatisfiedGeneration = 0
    private var catalogRefreshRetryAttempt = 0
    private var catalogDeferredFollowUpKey: SessionCatalogLoadKey?
    private var sceneAllowsCatalogRefresh = true
    private var cacheCheckpointTask: Task<Void, Never>?
    private var cacheCheckpointTaskGeneration = 0
    private var cacheCheckpointGeneration = 0
    private var pendingCacheCheckpoint: CacheCheckpoint?
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
        composerFileUpload: ComposerFileUploadOperation? = nil,
        composerAttachmentFileAccess: ComposerAttachmentFileAccess = .live,
        composerDraftStore: ComposerDraftStore = ComposerDraftStore(),
        extensionInteractionDrafts: ExtensionInteractionDraftStore = ExtensionInteractionDraftStore(),
        exportArtifacts: SessionExportArtifactStore = SessionExportArtifactStore()
    ) {
        let resolvedPairingCommit = pairingCommit ?? { profile, token in
            try profiles.save(profile, token: token, selecting: true)
        }
        let resolvedPairingCommitWithoutSelection: PairingCommit = { profile, token in
            try profiles.save(profile, token: token, selecting: false)
        }
        let resolvedProfileTokenLookup = profileTokenLookup ?? { profile in
            profiles.token(for: profile)
        }
        let noticeCenter = InAppNoticeCenter(clock: clock)
        let dashboardConnections = DashboardGatewayConnectionPool()
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: clock,
            reconnectDelayPolicy: reconnectDelayPolicy,
            uuidSource: uuidSource,
            pairer: pairer,
            pairingCommit: resolvedPairingCommit,
            pairingCommitWithoutSelection: resolvedPairingCommitWithoutSelection,
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
            performanceSignposts: performanceSignposts,
            clock: clock
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
            discardUpload: { uploadID in
                try? await client.discardUpload(uploadID)
            },
            fileUpload: composerFileUpload ?? { name, mimeType, fileURL, byteCount in
                try await client.upload(
                    name: name,
                    mimeType: mimeType,
                    fileURL: fileURL,
                    byteCount: byteCount
                )
            },
            attachmentFileAccess: composerAttachmentFileAccess,
            draftStore: composerDraftStore,
            send: { text, sessionID, uploadIDs, behavior, resourceInvocation in
                try await sessionMutations.prompt(
                    text,
                    sessionID: sessionID,
                    uploadIDs: uploadIDs,
                    behavior: behavior,
                    resourceInvocation: resourceInvocation
                )
            },
            admitsLifecycleGeneration: { lifecycle.admits(.init(generation: $0, connectionID: nil)) }
        )
        let gatewayDiagnostics = GatewayDiagnosticsService(client: client)
        let automationCatalog = AutomationCatalogCoordinator(endpoints: { @MainActor in
            profiles.profiles.filter { $0.isEnabled && profiles.token(for: $0) != nil }.map { profile in
                let state: DashboardServerConnectionState
                let capabilities: Set<String>
                if profile.id == lifecycle.selectedProfileID {
                    state = switch lifecycle.connectionState {
                    case .connected: .connected
                    case .connecting: .connecting
                    case .reconnecting: .reconnecting
                    case .restarting: .restarting
                    case .offline: .offline
                    case .unpaired: .offline
                    case .unauthorized: .blocked
                    }
                    capabilities = Set(lifecycle.gatewayInfo?.capabilities ?? [])
                } else {
                    state = dashboardConnections.state(for: profile.id) ?? .stale
                    // Only an authenticated, identity-checked pool handshake may
                    // advertise a background Gateway capability.
                    capabilities = Set(dashboardConnections.infoSnapshot(for: profile.id)?.capabilities ?? [])
                }
                let request: AutomationRPCClient.Request = { method, params, timeout in
                    if profile.id == lifecycle.selectedProfileID {
                        return try await client.requestValue(method, params, timeout: timeout)
                    }
                    return try await dashboardConnections.request(profileID: profile.id, method: method, params: params, timeout: timeout)
                }
                return AutomationGatewayEndpoint(
                    profile: AutomationDashboardProfile(id: profile.id, label: profile.label, state: state, capabilities: capabilities),
                    client: AutomationRPCClient(request: request, mutationExecutor: profile.id == lifecycle.selectedProfileID ? mutationExecutor : nil)
                )
            }
        })
        let workspaceInspection = WorkspaceInspectionService(client: client)
        let chatMedia = ChatMediaLoader(
            fetch: { identity in
                let value = try await client.blob(
                    id: identity.blobID,
                    sessionID: identity.sessionID,
                    profileID: identity.profileID,
                    maximumBytes: ChatMediaPolicy.maximumEncodedBytes
                )
                return ChatMediaPayload(data: value.0, mimeType: value.1)
            },
            admits: { identity in
                lifecycle.selectedProfileID == identity.profileID
                    && lifecycle.admits(.init(
                        generation: identity.lifecycleGeneration,
                        connectionID: nil
                    ))
            }
        )
        let chatMediaMemoryPressureObserver = ChatMediaMemoryPressureObserver(loader: chatMedia)
        let resolvedSessionImportUpload = sessionImportUpload ?? { name, mimeType, fileURL, byteCount in
            try await client.upload(
                name: name,
                mimeType: mimeType,
                fileURL: fileURL,
                byteCount: byteCount
            )
        }
        self.lifecycle = lifecycle
        self.noticeCenter = noticeCenter
        self.dashboardConnections = dashboardConnections
        self.automationCatalog = automationCatalog
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
        self.extensionInteractionDrafts = extensionInteractionDrafts
        self.gatewayDiagnostics = gatewayDiagnostics
        self.workspaceInspection = workspaceInspection
        self.chatMedia = chatMedia
        self.chatMediaMemoryPressureObserver = chatMediaMemoryPressureObserver
        self.sessionPresentation = sessionPresentation
        self.cache = cache
        self.clock = clock
        self.uuidSource = uuidSource
        self.performanceSignposts = performanceSignposts
        self.exportArtifacts = exportArtifacts
        dashboardConnections.delegate = self
        Task { try? await exportArtifacts.prune() }
        #if HOSTED_TEST
        if ProcessInfo.processInfo.arguments.contains("--tron-reset-ui-test-state") {
            for profile in profiles.profiles { try? profiles.remove(profile) }
            UserDefaults.standard.removeObject(forKey: "tronSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "piSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "defaultWorkspace.v1")
            extensionInteractionDrafts.removeAll()
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

    func sessionContextPresentation(for sessionID: String) -> SessionContextPresentation? {
        sessionPresentation.contextPresentation(for: sessionID)
    }

    func transcriptSnapshot(for sessionID: String) -> SessionSnapshot? {
        sessionPresentation.transcriptSnapshot(for: sessionID)
    }

    func displayArtifactFile(
        id: String,
        sessionID: String,
        profileID: String,
        maximumBytes: Int,
        expectedBytes: Int64
    ) async throws -> URL {
        try await client.displayArtifactFile(
            id: id,
            sessionID: sessionID,
            profileID: profileID,
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes
        )
    }

    func chatMediaIdentity(blobID: String, sessionID: String? = nil) -> ChatMediaIdentity? {
        guard let admission = lifecycle.generationAdmission,
              let profileID = lifecycle.selectedProfileID else { return nil }
        return ChatMediaIdentity(
            profileID: profileID,
            lifecycleGeneration: admission.generation,
            blobID: blobID,
            sessionID: sessionID
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

    func beginHostedReconciliationAggregate() {
        guard let admission = lifecycle.admission else { return }
        lifecycleBeginReconciliationAggregate(admission: admission)
    }

    func completeHostedReconciliationAggregate(succeeded: Bool) {
        guard let admission = reconciliationAggregateAdmission else { return }
        lifecycleCompleteReconciliationAggregate(admission: admission, succeeded: succeeded)
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

    /// Ordinary live commands require exact mounted authority. Stop deliberately
    /// bypasses this presentation gate: its route session ID and optional
    /// operation ID are fenced again by the Gateway, and the confirmed executor
    /// can carry that escape hatch through a short transport handoff.
    func hasMountedSessionAuthority(_ target: SessionPresentationTarget) -> Bool {
        SessionMountedAuthorityPolicy.admits(
            ownsPresentation: ownsPresentation(target),
            hasInstalledSubscription: sessionPresentation.hasInstalledSubscription(for: target.sessionID),
            snapshotSessionID: authoritativeSnapshot(for: target.sessionID)?.sessionId,
            targetSessionID: target.sessionID
        )
    }

    /// Live commands require the exact mounted subscription and authoritative
    /// snapshot, not merely a retained transcript or presentation lease.
    func admitsLiveSessionCommands(_ target: SessionPresentationTarget) -> Bool {
        guard connectionState == .connected,
              !isReconcilingForeground,
              hasMountedSessionAuthority(target),
              let snapshot = authoritativeSnapshot(for: target.sessionID) else { return false }
        // Extension interactions remain independently answerable, but another
        // composer mutation must not queue invisibly behind a command handler
        // that is running or waiting for input on the serialized session lane.
        return !snapshot.transcript.contains { item in
            guard item.semantic?.kind == .command else { return false }
            switch item.semantic?.lifecycle {
            case .completed, .failed, .interrupted, .outcomeUnknown:
                return false
            case .staged, .accepted, .running, .waitingForInput, .queued, .retrying, .settling, nil:
                return true
            }
        }
    }

    func setSessionPresentationVisible(_ target: SessionPresentationTarget, visible: Bool) {
        sessionPresentation.setPresentationVisible(target, visible: visible)
    }

    func revokePresentationIntake(_ target: SessionPresentationTarget) {
        cancelExtensionEditorSynchronization(for: target)
        composerDrafts.revoke(target)
        sessionPresentation.revokeIntake(target)
    }

    func presentComposerActionError(_ error: Error, target: SessionPresentationTarget) {
        guard composerDrafts.admits(target), !(error is CancellationError) else { return }
        presentError(error)
    }

    func presentComposerActionError(_ message: String, target: SessionPresentationTarget) {
        guard composerDrafts.admits(target) else { return }
        presentError(message)
    }

    var mountedPresentationTarget: SessionPresentationTarget? {
        sessionPresentation.mountedTarget
    }

    var admitsSessionPresentationOpen: Bool {
        // A new authoritative open is itself a projection-recovery operation.
        // Once the replacement transport is active it must not wait behind
        // unrelated mounted/catalog reconciliation from the prior epoch.
        connectionState == .connected
            && lifecycle.admission?.connectionID != nil
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

    func dashboardServerState(for profileID: String) -> DashboardServerConnectionState {
        _ = profileRevision
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return .stale }
        if !profile.isEnabled { return .disabled }
        if profiles.selected?.id == profile.id {
            switch connectionState {
            case .connected: return .connected
            case .connecting: return .connecting
            case .reconnecting: return .reconnecting
            case .restarting: return .restarting
            case .offline: return .offline
            case .unpaired, .unauthorized: return .stale
            }
        }
        if profile.machineGroupID == profile.machineId { return .needsVerification }
        if profiles.profiles.contains(where: {
            $0.id != profile.id && $0.isEnabled && $0.machineGroupID == profile.machineGroupID
        }) { return .blocked }
        return dashboardStatesByProfile[profile.id] ?? .stale
    }

    var dashboardServerSources: [DashboardServerSource] {
        _ = profileRevision
        return profiles.profiles.map { profile in
            DashboardServerSource(
                profileID: profile.id,
                label: profile.label,
                sessionCount: (dashboardSessionsByProfile[profile.id] ?? []).count,
                state: dashboardServerState(for: profile.id)
            )
        }
    }

    var visibleSessions: [SessionSummary] {
        _ = profileRevision
        let selectedProfile = profiles.selected
        let values = Self.dashboardProjection(
            selectedProfileID: selectedProfile?.id,
            selectedProfileLabel: selectedProfile?.label,
            selectedSessions: sessions,
            buckets: dashboardSessionsByProfile
        )
        return SessionSummary.orderedForDashboard(SessionSummary.dashboardSessions(values))
    }

    nonisolated static func dashboardProjection(
        selectedProfileID: String?,
        selectedProfileLabel: String?,
        selectedSessions: [SessionSummary],
        buckets: [String: [SessionSummary]]
    ) -> [SessionSummary] {
        // A selected profile without an installed bucket is still authoritative;
        // retain background buckets without letting them hide its rows. Merge by
        // source-qualified dashboard identity so equal session IDs stay distinct.
        guard let selectedProfileID, buckets[selectedProfileID] == nil else {
            return buckets.values.flatMap { $0 }.isEmpty ? selectedSessions : buckets.values.flatMap { $0 }
        }
        var merged = buckets.values.flatMap { $0 }.reduce(into: [String: SessionSummary]()) { result, session in
            result[session.dashboardID] = session
        }
        for session in selectedSessions {
            let sourced = session.withGatewaySource(
                id: selectedProfileID,
                label: selectedProfileLabel ?? selectedProfileID
            )
            merged[sourced.dashboardID] = sourced
        }
        return Array(merged.values)
    }

    func dashboardActivity(for sessionID: String) -> DashboardSessionActivity {
        sessionCatalog.activity(for: sessionID)
    }

    func dashboardActivity(for session: SessionSummary) -> DashboardSessionActivity {
        guard let profileID = session.gatewayProfileID,
              profileID != profiles.selected?.id else {
            return sessionCatalog.activity(for: session.id)
        }
        let live = dashboardStatesByProfile[profileID] == .connected
        guard live else { return session.phase == .idle ? .idle : .resuming }
        if session.waitingForUser { return .waitingForUser }
        if session.phase.isActive {
            return session.hasOnlyActiveSubagents ? .subagentsWorking : .active
        }
        return session.phase == .interrupted ? .interrupted : .idle
    }

    func postNotice(
        _ message: String,
        replacing key: InAppNoticeKey? = nil,
        role: InAppNoticeCenter.Role = .info,
        lifetime: InAppNoticeCenter.Lifetime = .standard,
        scope: InAppNoticeScope = .app,
        priority: InAppNoticeCenter.Priority = .normal
    ) {
        let replacement = key.map { InAppNoticeReplacement(key: $0, scope: scope) }
        noticeCenter.post(.init(
            id: uuidSource.next(), replacement: replacement, scope: scope,
            role: role, priority: priority, title: message, lifetime: lifetime
        ))
    }

    func removeNotice(_ key: InAppNoticeKey, scope: InAppNoticeScope? = nil) {
        for notice in noticeCenter.notices where notice.replacement?.key == key && (scope == nil || notice.scope == scope) {
            noticeCenter.dismiss(notice.id)
        }
    }

    func presentError(
        _ message: String,
        viewLogs: Bool = false,
        scope: InAppNoticeScope = .app,
        replacing key: InAppNoticeKey? = nil
    ) {
        let action: InAppNoticeCenter.Action? = viewLogs
            ? .init(id: "view-logs", title: "View Logs", role: .normal)
            : nil
        let lifetime: InAppNoticeCenter.Lifetime = viewLogs ? .persistent : .automatic(.seconds(8))
        let id = uuidSource.next()
        noticeCenter.post(
            .init(
                id: id,
                replacement: key.map { InAppNoticeReplacement(key: $0, scope: scope) },
                scope: scope,
                role: .error,
                priority: .high,
                title: message,
                lifetime: lifetime,
                actions: action.map { [$0] } ?? []
            ),
            handlers: viewLogs ? ["view-logs": { [weak self] in
                self?.logsPresentationRequested = true
            }] : [:]
        )
    }

    func presentError(
        _ error: Error,
        scope: InAppNoticeScope = .app,
        replacing key: InAppNoticeKey? = nil
    ) {
        let diagnostic = (error as? GatewayFailure)?.code == "invalid_response"
        presentError(
            error.localizedDescription,
            viewLogs: diagnostic,
            scope: scope,
            replacing: key
        )
        if let failure = error as? GatewayFailure, diagnostic {
            iosClientDiagnostics.record(failure, profileID: profiles.selected?.id, profileLabel: profiles.selected?.label)
        }
    }

    func consumeLogsPresentationRequest() { logsPresentationRequested = false }

    func presentConfigurationActionError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        presentError(error)
    }

    func start(sceneIsActive: Bool = true) async {
        sceneAllowsCatalogRefresh = sceneIsActive
        pushNavigationActivationReady = sceneIsActive
        await lifecycle.start()
        didStart = true
        if sceneAllowsCatalogRefresh {
            reconcileDashboardConnections()
        }
    }

    func becameInactive() {
        pushNavigationActivationReady = false
        pushNavigationActivationGeneration &+= 1
        noticeCenter.setBackgrounded(true)
    }

    @discardableResult
    func becameActive() -> Task<Void, Never>? {
        sceneAllowsCatalogRefresh = true
        pushNavigationActivationReady = false
        pushNavigationActivationGeneration &+= 1
        let activationGeneration = pushNavigationActivationGeneration
        noticeCenter.setBackgrounded(false)
        let requiresRetirementBarrier = lifecycle.routeActivationRequiresRetirementBarrier
        let lifecycleTask = lifecycle.becameActive()
        return Task { @MainActor [weak self] in
            // A true background transition must first finish retiring the old
            // socket; an inactive/active transition already has a safe route
            // transport and must not wait for full foreground reconciliation.
            if requiresRetirementBarrier, let lifecycleTask { await lifecycleTask.value }
            guard let self else { return }
            await self.dashboardConnections.waitForRetirement()
            guard self.sceneAllowsCatalogRefresh,
                  self.pushNavigationActivationGeneration == activationGeneration else { return }
            self.pushNavigationActivationReady = true
            if !requiresRetirementBarrier, let lifecycleTask { await lifecycleTask.value }
            guard self.sceneAllowsCatalogRefresh,
                  self.pushNavigationActivationGeneration == activationGeneration else { return }
            self.reconcileDashboardConnections()
        }
    }

    @discardableResult
    func enteredBackground() -> Task<Void, Never> {
        sceneAllowsCatalogRefresh = false
        pushNavigationActivationReady = false
        pushNavigationActivationGeneration &+= 1
        noticeCenter.setBackgrounded(true)
        diagnosticsAreReady = false
        reconciliationAggregateAdmission = nil
        isReconcilingForeground = false
        dashboardConnections.retire()
        // The canonical session may still be running on the Gateway, but this
        // mobile projection is intentionally retiring its transport lease.
        sessionCatalog.markDisconnected()
        let draftCheckpoint = composerDrafts.checkpointDrafts()
        lifecycle.enteredBackground()
        catalogInvalidationGeneration &+= 1
        cancelCatalogRefresh()
        // Provider login is stable-device-owned on the Gateway. Retire only
        // this transport delivery epoch and retain the operation for auth.resume.
        providerAuth.retireConnection()
        return draftCheckpoint
    }

    func pair(_ invitation: PairingInvitation, selectingProfile: Bool = true) async throws {
        do {
            try await lifecycle.pair(invitation, selectingProfile: selectingProfile)
        } catch {
            // The credential commit can succeed immediately before a later
            // handshake/projection failure. Reconcile the old pool even when
            // pairing reports failure so two same-machine profiles never stay
            // live after a partial selection transition.
            profileRevision &+= 1
            reconcileDashboardConnections()
            throw error
        }
        profileRevision &+= 1
        reconcileDashboardConnections()
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

    private func requireCurrentGatewayConnection() throws -> GatewayLifecycleCoordinator.Admission {
        guard let admission = lifecycle.admission,
              admission.connectionID != nil else { throw CancellationError() }
        return admission
    }

    private func invalidateProfileScopedLoads() {
        cancelCatalogRefresh()
        sessionCatalog.invalidateLoads()
        workspaceLoadGeneration &+= 1
        deviceLoadGeneration &+= 1
        legacyImportLoadGeneration &+= 1
    }

    private func clearGatewayProjection() {
        // Preserve the focused catalog as a bounded stale dashboard bucket
        // before clearing the live projection. Selecting another server must
        // not make the previous server's sessions disappear from All servers.
        clearLiveConnectionProjection()
        sessionCatalog.clear()
        sessionPresentation.clearProfile()
        pairedDevices.removeAll()
        legacyImportAvailable = false
        legacyImportedCount = 0
        workspace = nil
        providerAuth.clearProfile()
        settingsTrust.clearProfile()
        packageConfiguration.clearProfile()
        customModelConfiguration.clearProfile()
        cancelAllExtensionEditorSynchronization()
        composerDrafts.retireProfilePresentation()
        noticeCenter.dismissAll()
    }

    func switchGateway(_ profile: GatewayProfile) async {
        // Keep the target's last bounded dashboard bucket while its focused
        // connection transitions. The authoritative catalog replaces it after
        // the switch; deleting it here exposes an avoidable empty/reordered
        // projection beneath translucent sheets.
        await lifecycle.switchGateway(profile)
        profileRevision &+= 1
        reconcileDashboardConnections()
    }

    func setGatewayEnabled(_ enabled: Bool, profile: GatewayProfile) {
        do {
            try profiles.setEnabled(enabled, for: profile)
            profileRevision &+= 1
            reconcileDashboardConnections()
        } catch {
            presentError(error)
        }
    }

    func disableGateway(_ profile: GatewayProfile) async {
        if profiles.selected?.id == profile.id {
            guard let replacement = profiles.profiles.first(where: { $0.id != profile.id && $0.isEnabled }) else {
                presentError("Keep at least one server enabled before disabling this server.")
                return
            }
            await switchGateway(replacement)
        }
        setGatewayEnabled(false, profile: profile)
    }

    func forgetGateway(_ profile: GatewayProfile) async {
        if profiles.selected?.id == profile.id {
            await forgetCurrentGateway()
            return
        }
        do {
            try profiles.remove(profile)
            await composerDrafts.removeProfile(profile.id).value
            await cache.remove(profileID: profile.id)
            profileRevision &+= 1
            reconcileDashboardConnections()
        } catch {
            presentError(error)
        }
    }

    func forgetCurrentGateway() async {
        let forgottenProfileID = profiles.selected?.id
        if await lifecycle.forgetCurrentGateway() {
            if let forgottenProfileID {
                await composerDrafts.removeProfile(forgottenProfileID).value
                await cache.remove(profileID: forgottenProfileID)
            }
            profileRevision &+= 1
            reconcileDashboardConnections()
            setupComplete = false
        }
    }

    func teardown() async {
        await composerDrafts.checkpointDrafts().value
        await lifecycle.teardown()
    }

    func restoreMountedPresentationAfterReconnect() async -> Bool {
        await sessionPresentation.reconnectMountedPresentation()
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
        catalogInvalidationGeneration &+= 1
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
    private func startCatalogRefresh(
        key: SessionCatalogLoadKey,
        delay: Duration = .zero
    ) -> Task<SessionCatalogRefreshOutcome, Never> {
        catalogRefreshRequestGeneration &+= 1
        let requestGeneration = catalogRefreshRequestGeneration
        let task = Task<SessionCatalogRefreshOutcome, Never> { @MainActor [weak self] in
            guard let self else { return SessionCatalogRefreshOutcome.retained }
            do { try await self.clock.sleep(delay) } catch { return .retained }
            let outcome = await self.runCatalogRefreshLease(key: key, requestGeneration: requestGeneration)
            if self.catalogRefreshRequestGeneration == requestGeneration,
               self.catalogRefreshKey == key {
                let needsFollowUp = self.catalogDeferredFollowUpKey == key
                let remainsDirty = self.catalogSatisfiedGeneration < self.catalogInvalidationGeneration
                self.catalogDeferredFollowUpKey = nil
                self.catalogRefreshTask = nil
                self.catalogRefreshKey = nil
                if self.currentCatalogLoadKey() == key {
                    if needsFollowUp {
                        _ = self.startCatalogRefresh(key: key)
                    } else if DashboardCatalogRetryPolicy.shouldRetry(
                        isDirty: remainsDirty,
                        isCurrent: true,
                        transportFailed: outcome == .transportFailure
                    ) {
                        self.catalogRefreshRetryAttempt = min(3, self.catalogRefreshRetryAttempt + 1)
                        _ = self.startCatalogRefresh(
                            key: key,
                            delay: Self.catalogRefreshRetryDelay(attempt: self.catalogRefreshRetryAttempt)
                        )
                    }
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
            if outcome == .published {
                catalogSatisfiedGeneration = max(catalogSatisfiedGeneration, observedInvalidation)
                catalogRefreshRetryAttempt = 0
            }
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
                        Params(cursor: cursor, limit: pageLimit, scope: "user"),
                        timeout: .seconds(10)
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
                installSelectedDashboardCatalog()
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
                let outcome = Self.catalogFailureOutcome(error)
                let activeConnectionID = await client.activeConnectionID()
                if outcome == .transportFailure,
                   activeConnectionID == key.connectionID {
                    // An RPC timeout or application-level "disconnected" error
                    // does not prove that the shared WebSocket epoch died.
                    // Transport receive failure owns epoch retirement.
                    return .retained
                }
                return outcome
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

    private static func catalogRefreshRetryDelay(attempt: Int) -> Duration {
        .seconds(min(8, 1 << min(3, max(1, attempt))))
    }

    private func cancelCatalogRefresh() {
        catalogRefreshRequestGeneration &+= 1
        catalogRefreshRetryAttempt = 0
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
            let admitted = try PairedDeviceCatalogPolicy.admit(response.devices)
            guard deviceLoadGeneration == generation else { return }
            pairedDevices = admitted
        } catch {
            guard deviceLoadGeneration == generation else { return }
            surface(error)
        }
    }

    func gatewayInfo(for profileID: String) async -> GatewayInfo? {
        if profiles.selected?.id == profileID { return gatewayInfo }
        return await dashboardConnections.info(for: profileID)
    }

    nonisolated static func supportsGatewayUpdate(capabilities: [String]) -> Bool {
        capabilities.contains("gateway-update.v1")
    }

    func loadGatewayUpdateConfig(for profile: GatewayProfile) async -> GatewayUpdateConfig? {
        // Update metadata is control-plane state. Never reading it may change
        // the focused chat server; the user must explicitly choose this server.
        guard profiles.selected?.id == profile.id,
              let admission = lifecycle.generationAdmission else { return nil }
        do {
            try requireLifecycle(admission)
            let config: GatewayUpdateConfig? = try await client.request(
                "gateway.update.config.status",
                EmptyParams(),
                as: GatewayUpdateConfig?.self,
                timeout: .seconds(10)
            )
            try requireLifecycle(admission)
            return config
        } catch let failure as GatewayFailure where failure.code == "not_found" || failure.code == "unsupported" {
            return nil
        } catch {
            guard admitsLifecycle(admission) else { return nil }
            surface(error)
            return nil
        }
    }

    @discardableResult
    func configureGatewayUpdate(
        for profile: GatewayProfile,
        sourceRoot: String,
        artifactRoot: String? = nil
    ) async -> GatewayUpdateConfig? {
        guard profiles.selected?.id == profile.id,
              let admission = lifecycle.generationAdmission else { return nil }
        do {
            try requireLifecycle(admission)
            let admittedSourceRoot = try GatewayUpdateConfigPolicy.admitPath(sourceRoot, name: "source repository")
            let admittedArtifactRoot = try artifactRoot.map {
                try GatewayUpdateConfigPolicy.admitPath($0, name: "artifact root")
            }
            struct Params: Encodable {
                let commandId: String
                let sourceRoot: String
                let artifactRoot: String?

                private enum CodingKeys: String, CodingKey { case commandId, sourceRoot, artifactRoot }

                func encode(to encoder: Encoder) throws {
                    var values = encoder.container(keyedBy: CodingKeys.self)
                    try values.encode(commandId, forKey: .commandId)
                    try values.encode(sourceRoot, forKey: .sourceRoot)
                    if let artifactRoot { try values.encode(artifactRoot, forKey: .artifactRoot) }
                }
            }
            let commandID = uuidSource.next().uuidString
            let config: GatewayUpdateConfig = try await mutationExecutor.perform(method: "gateway.update.config", commandID: commandID) {
                try await self.client.request(
                    "gateway.update.config",
                    Params(commandId: commandID, sourceRoot: admittedSourceRoot, artifactRoot: admittedArtifactRoot),
                    as: GatewayUpdateConfig.self,
                    timeout: .seconds(30)
                )
            }
            try requireLifecycle(admission)
            return config
        } catch {
            guard admitsLifecycle(admission) else { return nil }
            surface(error)
            return nil
        }
    }

    func loadGatewayUpdateStatus(for profile: GatewayProfile) async -> GatewayUpdateStatus? {
        // See loadGatewayUpdateConfig: status reads must not retarget the
        // focused profile as a side effect.
        guard profiles.selected?.id == profile.id,
              let admission = lifecycle.generationAdmission else { return nil }
        do {
            try requireLifecycle(admission)
            struct Params: Codable { let channel: String }
            let status: GatewayUpdateStatus = try await client.request(
                "gateway.update.status",
                Params(channel: profile.gatewayChannel),
                as: GatewayUpdateStatus.self,
                timeout: .seconds(10)
            )
            try requireLifecycle(admission)
            return status
        } catch let failure as GatewayFailure where failure.code == "not_found" || failure.code == "unsupported" {
            return nil
        } catch {
            guard admitsLifecycle(admission) else { return nil }
            surface(error)
            return nil
        }
    }

    nonisolated static func supportsAdministrativeDrainStatus(capabilities: [String]) -> Bool {
        capabilities.contains("drain-status.v1")
    }

    func loadAdministrativeDrainStatus(for profile: GatewayProfile) async throws -> AdministrativeDrainSnapshot? {
        guard profiles.selected?.id == profile.id,
              connectionState == .connected,
              Self.supportsAdministrativeDrainStatus(capabilities: gatewayInfo?.capabilities ?? []),
              let admission = lifecycle.generationAdmission else { return nil }
        try requireLifecycle(admission)
        do {
            let snapshot: AdministrativeDrainSnapshot = try await client.request(
                "gateway.drain.status",
                EmptyParams(),
                timeout: .seconds(10)
            )
            try requireLifecycle(admission)
            return snapshot
        } catch let failure as GatewayFailure where failure.code == "not_found" || failure.code == "unsupported" {
            return nil
        }
    }

    func requestGatewayUpdate(
        for profile: GatewayProfile,
        mode: String = "source",
        debugCandidate: GatewayDebugPromotionCandidate? = nil
    ) async -> String? {
        guard profiles.selected?.id == profile.id,
              let admission = lifecycle.generationAdmission else { return nil }
        do {
            try requireLifecycle(admission)
            guard Self.supportsGatewayUpdate(capabilities: gatewayInfo?.capabilities ?? []) else {
                throw GatewayFailure(
                    code: "unsupported",
                    message: "This Gateway is not managed by a LaunchAgent-owned update helper.",
                    retryable: false,
                    details: nil
                )
            }
            guard ["source", "artifact"].contains(mode) else {
                throw GatewayFailure(code: "invalid_request", message: "The Gateway update mode is invalid.", retryable: false, details: nil)
            }
            if mode == "artifact" {
                guard profile.gatewayChannel == "stable", debugCandidate != nil else {
                    throw GatewayFailure(code: "invalid_request", message: "A tested Debug promotion requires complete verified provenance for its exact Stable candidate.", retryable: false, details: nil)
                }
            } else if debugCandidate != nil {
                throw GatewayFailure(code: "invalid_request", message: "Debug candidate provenance is valid only for exact artifact promotion.", retryable: false, details: nil)
            }
            let candidateVersion = debugCandidate?.version
            let candidateFingerprint = debugCandidate?.payloadFingerprint
            struct Params: Codable {
                let commandId: String
                let channel: String
                let mode: String
                let candidateVersion: String?
                let candidateFingerprint: String?
            }
            let commandID = uuidSource.next().uuidString
            let acknowledgement: GatewayUpdateAcknowledgement = try await mutationExecutor.perform(
                method: "gateway.update",
                commandID: commandID
            ) {
                try await self.client.request(
                    "gateway.update",
                    Params(commandId: commandID, channel: profile.gatewayChannel, mode: mode, candidateVersion: candidateVersion, candidateFingerprint: candidateFingerprint),
                    as: GatewayUpdateAcknowledgement.self,
                    timeout: .seconds(30)
                )
            }
            try acknowledgement.require(commandID: commandID)
            try requireLifecycle(admission)
            // The helper acknowledgement only means the detached updater was
            // admitted. Enter restarting when the Gateway emits
            // system.stopping, so an accepted update cannot make iOS look
            // offline while the old process is still serving sessions.
            postNotice("Gateway update accepted. Tron will reconnect automatically.", replacing: .gatewayRestart, role: .progress, lifetime: .standard, priority: .low)
            return commandID
        } catch {
            guard admitsLifecycle(admission) else { return nil }
            surface(error)
            return nil
        }
    }

    func requestGatewayRollback(for profile: GatewayProfile) async -> String? {
        guard profiles.selected?.id == profile.id,
              let admission = lifecycle.generationAdmission else { return nil }
        do {
            try requireLifecycle(admission)
            guard Self.supportsGatewayUpdate(capabilities: gatewayInfo?.capabilities ?? []) else {
                throw GatewayFailure(code: "unsupported", message: "This Gateway does not support supervised payload rollback.", retryable: false, details: nil)
            }
            struct Params: Codable { let commandId: String; let channel: String }
            let commandID = uuidSource.next().uuidString
            let acknowledgement: GatewayUpdateAcknowledgement = try await mutationExecutor.perform(
                method: "gateway.rollback",
                commandID: commandID
            ) {
                try await self.client.request(
                    "gateway.rollback",
                    Params(commandId: commandID, channel: profile.gatewayChannel),
                    as: GatewayUpdateAcknowledgement.self,
                    timeout: .seconds(30)
                )
            }
            try acknowledgement.require(commandID: commandID)
            try requireLifecycle(admission)
            postNotice("Gateway rollback accepted. Tron will reconnect automatically.", replacing: .gatewayRestart, role: .progress, lifetime: .standard, priority: .low)
            return commandID
        } catch {
            guard admitsLifecycle(admission) else { return nil }
            surface(error)
            return nil
        }
    }

    func gatewayLogs(for profileID: String, limit: Int = 1_000) async throws -> [GatewayLogRecord] {
        guard limit >= 0 else { throw GatewayFailure(code: "invalid_request", message: "Log limit is invalid.", retryable: false, details: nil) }
        if profiles.selected?.id == profileID {
            return try await gatewayDiagnostics.logs(limit: limit)
        }
        guard let diagnostics = dashboardConnections.diagnostics(for: profileID) else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await diagnostics.logs(limit: limit)
    }

    func loadGatewayLogsResult(limit: Int = 1_000) async -> GatewayLogsLoadResult {
        let profileSnapshot = profiles.profiles
        var loaded = Array(iosClientDiagnostics.records.prefix(limit))
        loaded.append(contentsOf: chatInteractionTrace.diagnosticRecords(limit: limit))
        var failedProfileIDs: Set<String> = []
        for profile in profileSnapshot {
            do {
                let records = try await gatewayLogs(for: profile.id, limit: limit)
                loaded.append(contentsOf: records.map {
                    GatewayProfileLogRecord(profileID: profile.id, profileLabel: profile.label, record: $0)
                })
            } catch is CancellationError {
                return GatewayLogsLoadResult(
                    records: Array(loaded.sorted { $0.record.timestamp > $1.record.timestamp }.prefix(limit)),
                    failedProfileIDs: failedProfileIDs
                )
            } catch {
                failedProfileIDs.insert(profile.id)
            }
        }
        return GatewayLogsLoadResult(
            records: Array(loaded.sorted { $0.record.timestamp > $1.record.timestamp }.prefix(limit)),
            failedProfileIDs: failedProfileIDs
        )
    }

    func loadGatewayLogs(limit: Int = 1_000) async -> [GatewayProfileLogRecord] {
        await loadGatewayLogsResult(limit: limit).records
    }

    func loadAuthorizedDevices() async -> [GatewayAuthorizedDevice] {
        let profileSnapshot = profiles.profiles
        let selectedID = profiles.selected?.id
        if selectedID != nil {
            await refreshDevices()
            guard profiles.selected?.id == selectedID else { return [] }
        }

        var authorized: [GatewayAuthorizedDevice] = []
        for profile in profileSnapshot {
            let devices: [PairedDevice]
            if profile.id == selectedID {
                guard profiles.selected?.id == selectedID else { continue }
                devices = pairedDevices
            } else {
                do {
                    devices = try await dashboardConnections.devices(for: profile.id)
                } catch is CancellationError {
                    return authorized
                } catch {
                    continue
                }
            }
            authorized.append(contentsOf: devices.map {
                GatewayAuthorizedDevice(profileID: profile.id, profileLabel: profile.label, device: $0)
            })
        }
        return authorized
    }

    nonisolated static func supportsIosDeviceInstall(capabilities: [String]) -> Bool {
        capabilities.contains("ios-device-install.v2")
    }

    func loadIosDeviceInstallConfig(for authorized: GatewayAuthorizedDevice) async throws -> IosDeviceInstallConfig? {
        let admission = try selectedAdministrativeAdmission(for: authorized.profileID)
        struct Params: Codable { let deviceId: String }
        let config: IosDeviceInstallConfig? = try await client.request(
            "device.install.config.status",
            Params(deviceId: authorized.device.id),
            as: IosDeviceInstallConfig?.self,
            timeout: .seconds(10)
        )
        try requireLifecycle(admission)
        guard config?.deviceId == authorized.device.id else {
            if config == nil { return nil }
            throw GatewayFailure(code: "invalid_response", message: "The iOS install configuration belongs to another device.", retryable: true, details: nil)
        }
        return config
    }

    func configureIosDeviceInstall(
        for authorized: GatewayAuthorizedDevice,
        sourceRoot: String
    ) async throws -> IosDeviceInstallConfig {
        let admission = try selectedAdministrativeAdmission(for: authorized.profileID)
        let admittedSourceRoot = try GatewayUpdateConfigPolicy.admitPath(
            sourceRoot,
            name: "iOS source repository"
        )
        struct Params: Encodable {
            let commandId: String
            let deviceId: String
            let sourceRoot: String
        }
        let commandID = uuidSource.next().uuidString
        let params = Params(
            commandId: commandID,
            deviceId: authorized.device.id,
            sourceRoot: admittedSourceRoot
        )
        let config: IosDeviceInstallConfig = try await mutationExecutor.perform(
            method: "device.install.config",
            commandID: commandID
        ) {
            try await self.client.request("device.install.config", params, timeout: .seconds(30))
        }
        try requireLifecycle(admission)
        guard config.deviceId == authorized.device.id else {
            throw GatewayFailure(code: "invalid_response", message: "The saved iOS install configuration belongs to another device.", retryable: true, details: nil)
        }
        return config
    }

    func loadIosDeviceInstallStatus(for authorized: GatewayAuthorizedDevice) async throws -> IosDeviceInstallStatus? {
        let admission = try selectedAdministrativeAdmission(for: authorized.profileID)
        struct Params: Codable { let deviceId: String }
        let status: IosDeviceInstallStatus? = try await client.request(
            "device.install.status",
            Params(deviceId: authorized.device.id),
            as: IosDeviceInstallStatus?.self,
            timeout: .seconds(10)
        )
        try requireLifecycle(admission)
        guard status?.deviceId == authorized.device.id else {
            if status == nil { return nil }
            throw GatewayFailure(code: "invalid_response", message: "The iOS install status belongs to another device.", retryable: true, details: nil)
        }
        return status
    }

    @discardableResult
    func requestIosDeviceInstall(for authorized: GatewayAuthorizedDevice) async throws -> String {
        let admission = try selectedAdministrativeAdmission(for: authorized.profileID)
        struct Params: Codable { let commandId: String; let deviceId: String }
        let commandID = uuidSource.next().uuidString
        let acknowledgement: IosDeviceInstallAcknowledgement = try await mutationExecutor.perform(
            method: "device.install",
            commandID: commandID
        ) {
            try await self.client.request(
                "device.install",
                Params(commandId: commandID, deviceId: authorized.device.id),
                timeout: .seconds(30)
            )
        }
        try acknowledgement.require(commandID: commandID)
        try requireLifecycle(admission)
        postNotice(
            "iOS rebuild and install accepted. This app will relaunch after installation.",
            role: .progress,
            lifetime: .standard,
            priority: .low
        )
        return commandID
    }

    private func requireSelectedAdministrativeProfile(_ profileID: String) throws {
        guard profiles.selected?.id == profileID, connectionState == .connected else {
            throw GatewayFailure(
                code: "disconnected",
                message: "Use this server before changing its device installation settings.",
                retryable: true,
                details: nil
            )
        }
    }

    private func selectedAdministrativeAdmission(for profileID: String) throws -> GatewayLifecycleCoordinator.Admission {
        try requireSelectedAdministrativeProfile(profileID)
        guard Self.supportsIosDeviceInstall(capabilities: gatewayInfo?.capabilities ?? []) else {
            throw GatewayFailure(
                code: "unsupported",
                message: "This Mac does not expose supervised iOS device installation.",
                retryable: false,
                details: nil
            )
        }
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        try requireLifecycle(admission)
        return admission
    }

    func revokeDevice(_ id: String, for profileID: String) async throws {
        if profiles.selected?.id != profileID,
           let profile = profiles.profiles.first(where: { $0.id == profileID }) {
            await switchGateway(profile)
        }
        guard profiles.selected?.id == profileID else { throw CancellationError() }
        try await revokeDevice(id)
    }

    func revokeDevice(_ id: String) async throws {
        let expectedProfileID = profiles.selected?.id
        struct Params: Codable { let deviceId: String; let commandId: String }
        struct Response: Codable { let revoked: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(deviceId: id, commandId: commandID)
        let response: Response = try await mutationExecutor.perform(method: "device.revoke", commandID: commandID) {
            try await client.request("device.revoke", params)
        }
        guard profiles.selected?.id == expectedProfileID else { throw CancellationError() }
        if response.revoked {
            pairedDevices.removeAll { $0.id == id }
            if let profile = profiles.selected, profile.deviceId == id,
               await lifecycle.forget(profile: profile) {
                await composerDrafts.removeProfile(profile.id).value
                await cache.remove(profileID: profile.id)
                profileRevision &+= 1
                reconcileDashboardConnections()
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
        switch (route.gatewayProfileID, route.gatewayLifecycleGeneration) {
        case (nil, nil):
            // Bounded hosted/local routes have no transport owner.
            return true
        case let (gatewayProfileID?, generation?):
            return profiles.selected?.id == gatewayProfileID
                && lifecycle.admits(.init(generation: generation, connectionID: nil))
        default:
            // Partial ownership metadata is never a valid navigation grant.
            return false
        }
    }

    func requestPushNavigation(_ tap: PushNotificationTap) {
        guard tap.sessionID != nil, tap.machineID != nil else { return }
        pushNavigationSequence &+= 1
        pushNavigationRequest = PushNavigationRequest(id: pushNavigationSequence, tap: tap)
    }

    func refreshNotificationInbox() async {
        let enabled = notificationInboxProfiles()
        notificationInbox.retainProfiles(Set(enabled.map(\.id)))
        for profile in enabled { await refreshNotificationInbox(profile: profile) }
    }

    func markNotificationRead(_ item: NotificationInboxItem) async {
        guard item.notification.isUnread else { return }
        notificationInbox.markReadOptimistically(item)
        do {
            try await sendNotificationRead(profileID: item.profileID, id: item.notification.id)
            if let profile = profiles.profiles.first(where: { $0.id == item.profileID }) {
                await refreshNotificationInbox(profile: profile)
            }
        } catch {
            if let profile = profiles.profiles.first(where: { $0.id == item.profileID }) {
                await refreshNotificationInbox(profile: profile)
            }
            presentError((error as? GatewayFailure)?.message ?? "Unable to mark the notification read.")
        }
    }

    func markAllNotificationsRead() async {
        let profileIDs = notificationInbox.buckets.compactMap { $0.value.unreadCount > 0 ? $0.key : nil }
        guard !profileIDs.isEmpty else { return }
        notificationInbox.markAllReadOptimistically()
        for profileID in profileIDs {
            do {
                try await sendAllNotificationsRead(profileID: profileID)
            } catch {
                presentError((error as? GatewayFailure)?.message ?? "Unable to mark notifications read.")
            }
        }
        await refreshNotificationInbox()
    }

    private func markNotificationRead(requestID: String, machineID: String) async {
        guard let profile = notificationInboxProfiles().first(where: { $0.machineId == machineID }) else { return }
        do {
            let commandID = uuidSource.next().uuidString
            if profile.id == profiles.selected?.id {
                struct Params: Encodable { let commandId, requestId: String }
                _ = try await mutationExecutor.performValue(
                    method: "notification.inbox.read",
                    commandID: commandID
                ) {
                    try await self.client.request(
                        "notification.inbox.read",
                        Params(commandId: commandID, requestId: requestID)
                    ) as JSONValue
                }
            } else {
                try await dashboardConnections.markNotificationRead(
                    profileID: profile.id,
                    requestID: requestID,
                    commandID: commandID
                )
            }
            await refreshNotificationInbox(profile: profile)
        } catch {
            // Push navigation remains useful even if read-state reconciliation is temporarily offline.
        }
    }

    private func notificationInboxProfiles() -> [GatewayProfile] {
        _ = profileRevision
        var groups = Set<String>()
        let selectedID = profiles.selected?.id
        return profiles.profiles
            .filter(\.isEnabled)
            .sorted { ($0.id == selectedID ? 0 : 1, $0.label, $0.id) < ($1.id == selectedID ? 0 : 1, $1.label, $1.id) }
            .filter { groups.insert($0.machineGroupID).inserted }
    }

    private func refreshNotificationInbox(profile: GatewayProfile) async {
        let generation = notificationInbox.begin(profileID: profile.id)
        do {
            let snapshot = profile.id == profiles.selected?.id
                ? try await NotificationInboxGatewayClient.list(client: client)
                : try await dashboardConnections.notificationInbox(for: profile.id)
            notificationInbox.install(profile: profile, snapshot: snapshot, generation: generation)
        } catch let failure as GatewayFailure where failure.code == "unsupported" {
            notificationInbox.fail(
                profileID: profile.id,
                generation: generation,
                message: "Update the Gateway to view notifications."
            )
        } catch {
            notificationInbox.fail(
                profileID: profile.id,
                generation: generation,
                message: (error as? GatewayFailure)?.message ?? "Unable to load notifications."
            )
        }
    }

    private func sendNotificationRead(profileID: String, id: String) async throws {
        let commandID = uuidSource.next().uuidString
        if profileID == profiles.selected?.id {
            struct Params: Encodable { let commandId, id: String }
            _ = try await mutationExecutor.performValue(
                method: "notification.inbox.read",
                commandID: commandID
            ) {
                try await self.client.request(
                    "notification.inbox.read",
                    Params(commandId: commandID, id: id)
                ) as JSONValue
            }
        } else {
            try await dashboardConnections.markNotificationRead(profileID: profileID, id: id, commandID: commandID)
        }
    }

    private func sendAllNotificationsRead(profileID: String) async throws {
        let commandID = uuidSource.next().uuidString
        if profileID == profiles.selected?.id {
            struct Params: Encodable { let commandId: String }
            _ = try await mutationExecutor.performValue(
                method: "notification.inbox.readAll",
                commandID: commandID
            ) {
                try await self.client.request(
                    "notification.inbox.readAll",
                    Params(commandId: commandID)
                ) as JSONValue
            }
        } else {
            try await dashboardConnections.markAllNotificationsRead(profileID: profileID, commandID: commandID)
        }
    }

    func consumePushNavigation(_ requestID: Int) {
        guard pushNavigationRequest?.id == requestID else { return }
        pushNavigationRequest = nil
    }

    func acknowledgePushNavigation(_ tap: PushNotificationTap) {
        guard let requestID = tap.requestID, let route = tap.route else { return }
        Task { @MainActor [weak self] in
            await self?.markNotificationRead(requestID: requestID, machineID: route.machineID)
        }
    }

    func navigationRoute(for session: SessionSummary) async throws -> SessionNavigationRoute {
        let owner = try await activateDashboardProfile(session.gatewayProfileID ?? profiles.selected?.id)
        return SessionNavigationRoute(
            sessionID: session.id,
            editorText: nil,
            gatewayProfileID: owner.profileID,
            gatewayLifecycleGeneration: owner.lifecycleGeneration
        )
    }

    func navigationRoute(for tap: PushNotificationTap) async throws -> SessionNavigationRoute {
        guard let route = tap.route else { throw CancellationError() }
        guard let profile = pushNavigationProfile(machineID: route.machineID) else {
            throw GatewayFailure(
                code: "not_found",
                message: "The server for this notification is no longer paired.",
                retryable: false,
                details: nil
            )
        }
        guard didStart, sceneAllowsCatalogRefresh, pushNavigationActivationReady else {
            throw CancellationError()
        }
        // A selected profile may already be publishing its replacement socket
        // after foreground activation. Join that handoff; switching the same
        // profile would cancel the useful reconnect and start a second one.
        if profiles.selected?.id != profile.id {
            await switchGateway(profile)
        }
        guard profiles.selected?.id == profile.id,
              let generationAdmission = lifecycle.generationAdmission,
              let routeAdmission = await lifecycle.waitForRouteConnection(
                  profileID: profile.id,
                  until: clock.now() + PushNavigationConnectionPolicy.readinessDeadline,
                  admission: generationAdmission
              ),
              lifecycle.admits(routeAdmission) else {
            throw GatewayFailure(
                code: "disconnected",
                message: "The server for this notification is offline.",
                retryable: true,
                details: nil
            )
        }
        // The payload already carries the admitted canonical identity. Do not
        // gate chat availability on a potentially paginated dashboard catalog;
        // `session.open` remains the authoritative existence/permission check.
        acknowledgePushNavigation(tap)
        return SessionNavigationRoute(
            sessionID: route.sessionID,
            editorText: nil,
            gatewayProfileID: profile.id,
            gatewayLifecycleGeneration: routeAdmission.generation
        )
    }

    private func pushNavigationProfile(machineID: String) -> GatewayProfile? {
        let candidates = profiles.profiles.filter { $0.machineId == machineID && $0.isEnabled }
        return candidates.first(where: { $0.id == profiles.selected?.id }) ?? candidates.first
    }

    func performOnOwningGateway<Value>(
        _ session: SessionSummary,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let owner = try await activateDashboardProfile(session.gatewayProfileID ?? profiles.selected?.id)
        guard session.gatewayProfileID == nil || session.gatewayProfileID == owner.profileID else {
            throw CancellationError()
        }
        let value = try await operation()
        guard profiles.selected?.id == owner.profileID,
              gatewayConnectionID == owner.connectionID,
              lifecycle.admits(.init(generation: owner.lifecycleGeneration, connectionID: owner.connectionID)) else {
            throw CancellationError()
        }
        return value
    }

    private func activateDashboardProfile(_ profileID: String?) async throws -> DashboardMutationOwner {
        guard let profileID,
              let profile = profiles.profiles.first(where: { $0.id == profileID }),
              profiles.token(for: profile) != nil else { throw CancellationError() }
        if profiles.selected?.id != profileID {
            await switchGateway(profile)
        }
        guard profiles.selected?.id == profileID,
              connectionState == .connected,
              let admission = lifecycle.generationAdmission,
              let connectionID = gatewayConnectionID else { throw CancellationError() }
        return DashboardMutationOwner(
            profileID: profileID,
            lifecycleGeneration: admission.generation,
            connectionID: connectionID
        )
    }

    func createSession(cwd: String) async throws -> SessionNavigationRoute {
        try await createSession(cwd: cwd, sourceControl: nil)
    }

    func createSession(
        cwd: String,
        sourceControl: SessionSourceControlSelection?
    ) async throws -> SessionNavigationRoute {
        guard let admission = lifecycle.generationAdmission,
              let profileID = lifecycle.selectedProfileID else { throw CancellationError() }
        let sessionID = try await sessionMutations.createSession(cwd: cwd, sourceControl: sourceControl)
        try requireLifecycle(admission)
        guard lifecycle.selectedProfileID == profileID else { throw CancellationError() }
        defaultWorkspace = cwd
        UserDefaults.standard.set(cwd, forKey: "defaultWorkspace.v1")
        // Creation is authoritative before the dashboard catalog's next list
        // traversal. Reconcile in the shared lease without delaying navigation.
        scheduleSessionListRefresh()
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
        // A foreground scene can become active before background transport
        // retirement and reconnect have published their replacement socket.
        // Never start session.open against that target-free interval, even if
        // the last public connection state still reads as connected.
        guard let admission = lifecycle.admission,
              admission.connectionID != nil,
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

    /// Replaces one transiently malformed mounted projection with a fresh
    /// authoritative synchronization cut without changing route ownership.
    /// Chat presentation bounds this recovery to one attempt; persistent
    /// malformed authority still fails closed.
    func resynchronizeSessionPresentation(_ id: String, generation: Int) async throws {
        guard sessionPresentation.presentationGeneration(for: id) == generation else {
            throw CancellationError()
        }
        guard await sessionPresentation.reconnectMountedPresentation() else {
            throw GatewayFailure(
                code: "sync_failed",
                message: "Tron could not refresh this conversation.",
                retryable: true,
                details: nil
            )
        }
        guard sessionPresentation.presentationGeneration(for: id) == generation else {
            throw CancellationError()
        }
    }

    func closeSessionPresentation(_ id: String, generation: Int) async {
        let target = SessionPresentationTarget(sessionID: id, generation: generation)
        cancelExtensionEditorSynchronization(for: target)
        composerDrafts.revoke(target)
        await sessionPresentation.close(target)
    }

    func loadEarlierTranscript(sessionID: String, presentationGeneration: Int) async -> SessionTranscriptLoadResult {
        await sessionPresentation.loadEarlier(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration
        )
    }

    private func invalidateSessionConnectionOwnership() {
        cancelAllExtensionEditorSynchronization()
        // Transcript media is profile/lifecycle-owned HTTP state. A disposable
        // WebSocket epoch handoff must not cancel an open preview or evict its
        // thumbnail flight.
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
        guard admitsLiveSessionCommands(target) else { throw CancellationError() }
        _ = try await sessionMutations.prompt(
            text,
            sessionID: target.sessionID,
            uploadIDs: [],
            behavior: nil
        )
    }

    func beginComposerSubmission(
        target: SessionPresentationTarget,
        behavior: String? = nil,
        resourceInvocation: ComposerResourceInvocation? = nil,
        canonicalTranscript: [TranscriptItem] = [],
        queuedMessages: [SessionSnapshot.QueuedMessage] = []
    ) throws -> ComposerSubmissionSnapshot {
        guard admitsLiveSessionCommands(target) else { throw CancellationError() }
        return try composerDrafts.beginSubmission(
            target: target,
            behavior: behavior,
            resourceInvocation: resourceInvocation,
            canonicalTranscript: canonicalTranscript,
            queuedMessages: queuedMessages
        )
    }

    func sendComposer(_ submission: ComposerSubmissionSnapshot) async throws {
        try await composerDrafts.transmitSubmission(submission)
    }

    func sendComposer(
        target: SessionPresentationTarget,
        behavior: String? = nil,
        resourceInvocation: ComposerResourceInvocation? = nil,
        canonicalTranscript: [TranscriptItem] = [],
        queuedMessages: [SessionSnapshot.QueuedMessage] = []
    ) async throws {
        let submission = try beginComposerSubmission(
            target: target,
            behavior: behavior,
            resourceInvocation: resourceInvocation,
            canonicalTranscript: canonicalTranscript,
            queuedMessages: queuedMessages
        )
        try await sendComposer(submission)
    }

    func abort(
        sessionID: String,
        kind: String = "agent",
        operationID: String? = nil
    ) async {
        do {
            try await sessionMutations.abort(
                sessionID: sessionID,
                kind: kind,
                operationID: operationID
            )
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            presentError("Stop could not be delivered to the Mac. Reopen the session and try again.")
        } catch { surface(error) }
    }

    @discardableResult
    func abortSubagent(leaseID: String) async -> Bool {
        do {
            try await sessionMutations.abortSubagent(leaseID: leaseID)
            return true
        } catch is CancellationError {
            guard !Task.isCancelled else { return false }
            presentError("Stop could not be delivered to the Mac. Reopen the subagent session and try again.")
            return false
        } catch {
            surface(error)
            return false
        }
    }

    func clearQueue(sessionID: String) async throws {
        guard let target = presentationTarget(for: sessionID),
              admitsLiveSessionCommands(target) else { throw CancellationError() }
        // The confirmed response proves command completion, not the sequenced
        // queue projection. Gateway snapshot/event authority clears the rows.
        try await sessionMutations.clearQueue(sessionID: sessionID)
    }

    func replaceQueue(
        sessionID: String,
        expectedRevision: Int,
        items: [SessionSnapshot.QueuedMessage]
    ) async throws {
        guard let target = presentationTarget(for: sessionID),
              admitsLiveSessionCommands(target) else { throw CancellationError() }
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

    func setSessionUnread(_ session: SessionSummary, unread: Bool) async throws {
        let projection = try await performOnOwningGateway(session) {
            try await self.sessionMutations.setAttention(
                sessionID: session.id,
                unread: unread,
                throughCompletionRevision: session.completionRevision
            )
        }
        // The response is authoritative for cold rows where Gateway cannot
        // broadcast a full summary. Apply it monotonically; unknown rows remain
        // absent until a catalog admission publishes them.
        if sessionCatalog.applyAttention(sessionID: session.id, projection) {
            installSelectedDashboardCatalog()
            scheduleCacheCheckpoint()
        }
    }

    func compact(sessionID: String, instructions: String? = nil) async throws {
        try await sessionMutations.compact(sessionID: sessionID, instructions: instructions)
    }

    func setTools(_ tools: [String], sessionID: String) async throws {
        try await sessionMutations.setTools(tools, sessionID: sessionID)
    }

    func setExtensionToolsExpanded(
        sessionID: String,
        hostEpoch: String,
        presentationRevision: Int,
        expanded: Bool
    ) async throws {
        try await sessionMutations.setExtensionToolsExpanded(
            sessionID: sessionID,
            hostEpoch: hostEpoch,
            presentationRevision: presentationRevision,
            expanded: expanded
        )
    }

    func fork(
        sessionID: String,
        entryID: String,
        position: String = "at"
    ) async throws -> SessionNavigationRoute {
        guard let admission = lifecycle.generationAdmission,
              let profileID = lifecycle.selectedProfileID else { throw CancellationError() }
        // Fence the exact source before transport. Pi rekeys during the mutation,
        // so waiting for the response is too late to stop a structure event from
        // launching an obsolete tree/context read.
        let sourceTarget = sessionPresentation.presentationTarget(for: sessionID)
        if let sourceTarget,
           !sessionPresentation.beginForkTransition(sourceTarget) {
            throw CancellationError()
        }
        let outcome: SessionForkOutcome
        do {
            outcome = try await sessionMutations.fork(
                sessionID: sessionID,
                entryID: entryID,
                position: position
            )
        } catch {
            if let sourceTarget { sessionPresentation.cancelForkTransition(sourceTarget) }
            throw error
        }
        // Canonical success permanently retires only the captured source target;
        // a same-session remount that raced the request has a different generation
        // and must not be revoked by this completion.
        if let sourceTarget {
            sessionPresentation.commitForkTransition(sourceTarget)
            cancelExtensionEditorSynchronization(for: sourceTarget)
            composerDrafts.revoke(sourceTarget)
        }
        // Catalog convergence is authoritative but independent. Retain the
        // invalidation even if lifecycle replacement makes this route stale.
        scheduleSessionListRefresh()
        // The command receipt proves canonical creation, but it cannot authorize
        // navigation through a replacement connection or selected Gateway.
        try requireLifecycle(admission)
        guard lifecycle.selectedProfileID == profileID else { throw CancellationError() }
        postNotice("Session forked", replacing: .sessionForked, role: .success)
        return SessionNavigationRoute(
            sessionID: outcome.sessionID,
            editorText: outcome.selectedText,
            gatewayProfileID: profileID,
            gatewayLifecycleGeneration: admission.generation
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
        struct Response: Decodable {
            let blobId, name, mimeType: String
            let size: Int64?
        }
        let supportsLargeExports = gatewayInfo?.capabilities.contains("session-export.v2") == true
        let response: Response = try await client.request(
            "session.export",
            Params(sessionId: sessionID, format: format),
            timeout: .seconds(1_800)
        )
        guard sessionPresentation.ownsInstalledSubscription(
            sessionID: sessionID,
            token: subscriptionToken
        ) else { throw CancellationError() }
        try Task.checkCancellation()
        let admission: SessionExportDownloadAdmission
        do {
            admission = try SessionExportDownloadAdmission.resolve(
                supportsLargeExports: supportsLargeExports,
                declaredBytes: response.size
            )
        } catch SessionExportDownloadAdmissionError.invalidVersionedSize {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The Gateway did not describe a supported export size.",
                retryable: true,
                details: nil
            )
        } catch {
            throw GatewayFailure(
                code: "export_too_large",
                message: "This Gateway does not support large session exports.",
                retryable: false,
                details: nil
            )
        }
        let reservation = try await exportArtifacts.prepareDownload(
            expectedBytes: admission.reservedBytes
        )
        do {
            let stagedURL = try await client.blobFile(
                id: response.blobId,
                maximumBytes: admission.maximumBytes,
                expectedBytes: admission.expectedBytes
            )
            defer { BoundedHTTPFileStaging.shared.discard(stagedURL) }
            guard sessionPresentation.ownsInstalledSubscription(
                sessionID: sessionID,
                token: subscriptionToken
            ) else { throw CancellationError() }
            try Task.checkCancellation()
            let artifact = try await exportArtifacts.adopt(stagedURL,
                suggestedName: response.name,
                reservation: reservation
            )
            guard !Task.isCancelled, sessionPresentation.ownsInstalledSubscription(
                sessionID: sessionID,
                token: subscriptionToken
            ) else {
                await exportArtifacts.discard(artifact)
                throw CancellationError()
            }
            return artifact
        } catch {
            await exportArtifacts.cancelDownload(reservation)
            throw error
        }
    }

    func discardExportArtifact(_ artifact: URL) async {
        await exportArtifacts.discard(artifact)
    }

    func deleteSession(_ id: String) async throws {
        await sessionPresentation.closeSubscriptionIfInstalled(sessionID: id)
        try await sessionMutations.delete(sessionID: id)
        sessionPresentation.remove(sessionID: id)
        if let profileID = lifecycle.selectedProfileID {
            await composerDrafts.removeSession(profileID: profileID, sessionID: id).value
        }
        sessionCatalog.remove(id)
        installSelectedDashboardCatalog()
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

    func commandDetail(sessionID: String, command: CommandInfo) async throws -> CommandResourceDetail {
        guard let target = presentationTarget(for: sessionID),
              admitsLiveSessionCommands(target) else { throw CancellationError() }
        struct Params: Encodable {
            let sessionId: String
            let source: CommandInfo.Source
            let name: String
        }
        let detail: CommandResourceDetail = try await client.request(
            "session.commandDetail",
            Params(sessionId: sessionID, source: command.source, name: command.name)
        )
        guard presentationTarget(for: sessionID) == target,
              admitsLiveSessionCommands(target) else { throw CancellationError() }
        return try CommandResourceDetailPolicy.admit(detail, matching: command)
    }

    func loadResources(sessionID: String) async {
        await sessionPresentation.loadResources(sessionID: sessionID)
    }

    func reloadResources(sessionID: String) async throws {
        try await sessionMutations.reloadResources(sessionID: sessionID)
    }

    func upload(
        name: String,
        mimeType: String,
        data: Data,
        target: SessionPresentationTarget
    ) async throws {
        guard admitsLiveSessionCommands(target) else { throw CancellationError() }
        try await composerDrafts.upload(
            name: name,
            mimeType: mimeType,
            data: data,
            target: target
        )
    }

    func uploadBatch(
        _ candidates: [ComposerAttachmentUploadCandidate],
        target: SessionPresentationTarget
    ) async throws {
        guard admitsLiveSessionCommands(target) else { throw CancellationError() }
        try await composerDrafts.uploadBatch(candidates, target: target)
    }

    func uploadFile(
        _ url: URL,
        target: SessionPresentationTarget
    ) async throws {
        guard admitsLiveSessionCommands(target) else { throw CancellationError() }
        try await composerDrafts.uploadFile(url, target: target)
    }

    @discardableResult
    func refreshProviders(target: ProviderCatalogTarget) async -> Bool {
        await providerAuth.refreshCatalog(target: target)
    }

    func beginAuth(providerID: String, authType: String, target: ProviderCatalogTarget) async throws {
        let admission = try requireCurrentGatewayConnection()
        do {
            try await providerAuth.beginAuth(providerID: providerID, authType: authType, target: target)
            try requireConnection(admission)
        } catch {
            guard lifecycle.admits(admission) else {
                providerAuth.clearProfile()
                throw CancellationError()
            }
            throw error
        }
    }

    func answerAuth(_ value: String) async throws {
        let admission = try requireCurrentGatewayConnection()
        do {
            try await providerAuth.answerAuth(value)
            try requireConnection(admission)
        } catch {
            guard lifecycle.admits(admission) else {
                providerAuth.clearProfile()
                throw CancellationError()
            }
            throw error
        }
    }

    func submitBrowserAuthCallback(
        _ callback: ProviderOAuthCapturedCallback,
        operationID: String
    ) async throws {
        // Capture first even if the socket was replaced while the system
        // browser was open. ProviderAuthCoordinator keeps one memory-only
        // callback and submits it after auth.resume on the same profile.
        try await providerAuth.submitBrowserCallback(callback, operationID: operationID)
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

    func packageError(for target: PackageConfigurationTarget) -> String? {
        packageConfiguration.error(for: target)
    }

    @discardableResult
    func loadPackages(target: PackageConfigurationTarget, surfaceError: Bool = true) async -> Bool {
        await packageConfiguration.load(target: target, surfaceError: surfaceError)
    }

    @discardableResult
    func checkPackageUpdates(target: PackageConfigurationTarget, surfaceError: Bool = true) async -> Bool {
        await packageConfiguration.checkUpdates(target: target, surfaceError: surfaceError)
    }

    func mutatePackage(
        action: PackageMutationAction,
        source: String?,
        local: Bool,
        target: PackageConfigurationTarget,
        surfaceError: Bool = true
    ) async throws {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        do {
            try await packageConfiguration.mutate(action, source: source, local: local, target: target, surfaceError: surfaceError)
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
            _ = try await restartGateway(admission: admission)
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
    }

    nonisolated static func supportsSafeGatewayRestart(capabilities: [String]) -> Bool {
        capabilities.contains("restart-drain.v1") && capabilities.contains("restart-supervised.v1")
    }

    @discardableResult
    func restartGateway() async throws -> GatewayRestartResponse {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        do {
            return try await restartGateway(admission: admission)
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
    }

    @discardableResult
    func requestGatewayRestart() async -> GatewayRestartResponse? {
        do { return try await restartGateway() }
        catch { surface(error); return nil }
    }

    @discardableResult
    func requestGatewayRestart(for profile: GatewayProfile) async -> GatewayRestartResponse? {
        if profiles.selected?.id != profile.id {
            await switchGateway(profile)
        }
        guard profiles.selected?.id == profile.id else { return nil }
        return await requestGatewayRestart()
    }

    private func restartGateway(
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws -> GatewayRestartResponse {
        try requireLifecycle(admission)
        guard Self.supportsSafeGatewayRestart(capabilities: gatewayInfo?.capabilities ?? []) else {
            throw GatewayFailure(
                code: "unsupported",
                message: "This Gateway is not supervised for remote restart. Install or relaunch the managed Tron Mac app, then retry; direct foreground Gateway processes must be restarted from their supervisor.",
                retryable: false,
                details: nil
            )
        }
        struct Params: Codable { let commandId: String }
        let commandID = uuidSource.next().uuidString
        let response: GatewayRestartResponse
        do {
            response = try await mutationExecutor.perform(method: "gateway.restart", commandID: commandID) {
                try await client.request("gateway.restart", Params(commandId: commandID))
            }
        } catch {
            guard admitsLifecycle(admission) else { throw CancellationError() }
            throw error
        }
        try requireLifecycle(admission)
        if response.restarting && !response.scheduled { lifecycle.beginRestarting() }
        if response.scheduled {
            let blockerCount = response.drain?.blockerCount
            let detail = blockerCount.map {
                " after \($0) accepted operation\($0 == 1 ? " finishes" : "s finish")"
            } ?? " after accepted operations finish"
            postNotice(
                "Gateway restart scheduled\(detail).",
                replacing: .gatewayRestart,
                role: .progress,
                lifetime: .standard,
                priority: .low
            )
        } else {
            postNotice("Gateway is restarting. Tron will reconnect automatically.", replacing: .gatewayRestart, role: .progress, lifetime: .standard, priority: .low)
        }
        return response
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

    private func cancelExtensionEditorSynchronization(for target: SessionPresentationIdentity) {
        extensionEditorSyncTasks[target]?.cancel()
        extensionEditorSyncTasks[target] = nil
        extensionEditorPendingText[target] = nil
        extensionEditorPendingRevisions[target] = nil
        extensionEditorSyncGenerations[target] = nil
        extensionEditorOperationReceipts[target] = nil
    }

    private func cancelAllExtensionEditorSynchronization() {
        for task in extensionEditorSyncTasks.values { task.cancel() }
        extensionEditorSyncTasks.removeAll()
        extensionEditorPendingText.removeAll()
        extensionEditorPendingRevisions.removeAll()
        extensionEditorSyncGenerations.removeAll()
        extensionEditorOperationReceipts.removeAll()
    }

    /// Debounces composer echoes into one target-scoped serialized worker.
    func scheduleExtensionEditorUpdate(target: SessionPresentationIdentity, text: String) {
        guard ownsPresentation(target),
              let presentation = authoritativeSnapshot(for: target.sessionID)?.extensionPresentation,
              !presentation.hostEpoch.isEmpty else { return }
        // The editor and ordinary prompt RPCs share the Gateway's 192 KiB
        // UTF-8 boundary. Do not enqueue a request the Gateway must reject;
        // retain the complete local draft so the user can shorten it.
        guard SharedContentAdmissionPolicy.admitsPrompt(text) else {
            extensionEditorPendingText[target] = nil
            extensionEditorPendingRevisions[target] = nil
            return
        }
        extensionEditorPendingText[target] = text
        extensionEditorPendingRevisions[target, default: 0] &+= 1
        guard extensionEditorSyncTasks[target] == nil else { return }
        let generation = (extensionEditorSyncGenerations[target] ?? 0) + 1
        extensionEditorSyncGenerations[target] = generation
        extensionEditorSyncTasks[target] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    guard let pendingRevision = self.extensionEditorPendingRevisions[target] else { break }
                    try await Task.sleep(for: .milliseconds(300))
                    guard self.extensionEditorPendingRevisions[target] == pendingRevision else { continue }
                    guard self.ownsPresentation(target),
                          let current = self.authoritativeSnapshot(for: target.sessionID)?.extensionPresentation,
                          !current.hostEpoch.isEmpty,
                          let pending = self.extensionEditorPendingText.removeValue(forKey: target) else { break }
                    self.extensionEditorPendingRevisions[target] = nil
                    let operationID = self.uuidSource.next().uuidString
                    var receipts = self.extensionEditorOperationReceipts[target] ?? []
                    receipts.append(operationID)
                    if receipts.count > 128 { receipts.removeFirst(receipts.count - 128) }
                    self.extensionEditorOperationReceipts[target] = receipts
                    _ = try await self.sessionMutations.updateExtensionEditor(
                        sessionID: target.sessionID,
                        hostEpoch: current.hostEpoch,
                        baseRevision: current.semanticState.editorRevision,
                        operationID: operationID,
                        text: pending
                    )
                    guard self.ownsPresentation(target) else { break }
                }
            } catch is CancellationError {
                return
            } catch {
                // Connection lifecycle presents transport state.
            }
            if self.extensionEditorSyncGenerations[target] == generation {
                self.extensionEditorSyncTasks[target] = nil
                if self.extensionEditorPendingText[target] != nil { self.scheduleExtensionEditorUpdate(target: target, text: self.extensionEditorPendingText[target]!) }
            }
        }
    }

    func disposeExtensionEditorRequest(
        _ request: ComposerEditorRequest,
        disposition: ComposerEditorDisposition,
        target: SessionPresentationIdentity
    ) {
        guard ownsPresentation(target) else { return }
        composerDrafts.disposeEditorRequest(request, disposition: disposition, target: target)
        if let scope = composerDrafts.scope(for: target) {
            scheduleExtensionEditorUpdate(target: target, text: composerDrafts.text(for: scope))
        }
    }

    func answerInteraction(
        _ interaction: ExtensionInteraction,
        sessionID: String,
        value: JSONValue?,
        cancelled: Bool
    ) async throws {
        if interaction.method == .form,
           let snapshot = authoritativeSnapshot(for: sessionID),
           !snapshot.extensionPresentation.pendingInteractions.contains(where: {
               $0.id == interaction.id
                   && $0.hostEpoch == interaction.hostEpoch
                   && $0.presentationRevision == interaction.presentationRevision
                   && $0.method == .form
           }) {
            throw GatewayFailure(
                code: "conflict",
                message: "This form is no longer pending. Refresh the session.",
                retryable: true,
                details: nil
            )
        }
        try await sessionMutations.answerInteraction(
            interactionID: interaction.id,
            hostEpoch: interaction.hostEpoch,
            presentationRevision: interaction.presentationRevision,
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
        if event.topic.hasPrefix("session."),
           event.topic != "session.listChanged",
           event.topic != "session.summary",
           event.topic != "session.processTranscript.changed" {
            await sessionPresentation.admit(event)
            return
        }
        await handleDeliveredEvent(event, connectionID: connectionID)
    }

    private func handleDeliveredEvent(_ event: GatewayEvent, connectionID: Int?) async {
        switch event.topic {
        case "transport.disconnected", "system.stopping":
            if event.topic == "system.stopping" { lifecycle.beginRestarting() }
            lifecycle.noteDisconnected(connectionID: connectionID)
            // Authentication belongs to the paired device identity, not this
            // disposable socket. Retire prompt delivery while retaining the
            // operation ID/target for an exact auth.resume after reconnect.
            providerAuth.retireConnection()
            lifecycleInvalidateSessionConnectionOwnership()
            sessionCatalog.markDisconnected()
            // An established mobile connection ending is already the first
            // failure signal. Retry once immediately; the reconnect loop keeps
            // its bounded jittered backoff if the Gateway is genuinely down.
            lifecycle.requestReconnect(immediate: true, replaceExisting: event.topic == "system.stopping")
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
        case "notification.inbox.changed":
            if let profile = profiles.selected { await refreshNotificationInbox(profile: profile) }
        case "automation.changed":
            guard case .automationChanged = event.preparation else { return }
            automationCatalog.invalidate()
        case "packages.progress", "packages.completed":
            postNotice(
                event.topic == "packages.completed" ? "Package operation completed" : "Updating agent package…",
                replacing: .packageProgress,
                role: event.topic == "packages.completed" ? .success : .progress,
                lifetime: .standard,
                priority: event.topic == "packages.completed" ? .normal : .low
            )
        case "session.processTranscript.changed":
            if case .processTranscriptChanged(let changed) = event.preparation {
                processTranscriptInvalidation = changed
            }
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

    private func apply(_ update: SessionSummaryUpdate) {
        sessionPresentation.observeAttentionSummary(update)
        switch sessionCatalog.apply(update) {
        case .stale:
            return
        case .unknownSession:
            scheduleSessionListRefresh()
        case .updated:
            installSelectedDashboardCatalog()
            scheduleCacheCheckpoint()
        }
    }

    private func installSelectedDashboardCatalog() {
        guard let profile = profiles.selected else {
            dashboardPresentationRevision &+= 1
            return
        }
        dashboardSessionsByProfile[profile.id] = sessionCatalog.sessions.map {
            $0.withGatewaySource(id: profile.id, label: profile.label)
        }
        dashboardPresentationRevision &+= 1
    }

    private func adoptConnectedGatewayIdentity() {
        guard let profile = profiles.selected,
              let info = gatewayInfo,
              info.machineId == profile.machineId,
              profile.machineGroupID == profile.machineId,
              info.machineGroupID != profile.machineGroupID else { return }
        var updated = profile
        updated.machineGroupID = info.machineGroupID
        do {
            try profiles.update(updated)
            profileRevision &+= 1
        } catch {
            // Group identity is a presentation-side safety hint. Keep the
            // authenticated runtime usable if metadata repair is unavailable.
            presentError(error)
        }
    }

    private func reconcileDashboardConnections() {
        dashboardCacheLoadGeneration &+= 1
        let cacheGeneration = dashboardCacheLoadGeneration
        let selectedProfileID = profiles.selected?.id
        let currentProfileIDs = Set(profiles.profiles.map(\.id))
        for profileID in Array(dashboardSessionsByProfile.keys) where !currentProfileIDs.contains(profileID) {
            dashboardSessionsByProfile[profileID] = nil
        }
        for profileID in Array(dashboardStatesByProfile.keys) where !currentProfileIDs.contains(profileID) {
            dashboardStatesByProfile[profileID] = nil
        }
        dashboardPresentationRevision &+= 1
        dashboardConnections.reconcile(
            profiles: profiles.profiles,
            selectedProfileID: selectedProfileID,
            token: { [profiles] profile in profiles.token(for: profile) }
        )
        for profile in profiles.profiles where profile.id != selectedProfileID {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cached = await self.cache.load(profileID: profile.id)
                guard self.dashboardCacheLoadGeneration == cacheGeneration,
                      self.profiles.profiles.contains(where: { $0.id == profile.id }),
                      self.profiles.selected?.id != profile.id,
                      self.dashboardStatesByProfile[profile.id] != .connected,
                      self.dashboardSessionsByProfile[profile.id]?.isEmpty != false else { return }
                self.dashboardSessionsByProfile[profile.id] = cached.sessions.map {
                    $0.withGatewaySource(id: profile.id, label: profile.label)
                }
                self.dashboardStatesByProfile[profile.id] = .stale
                self.dashboardPresentationRevision &+= 1
            }
        }
    }

    private func scheduleSessionListRefresh() {
        catalogInvalidationGeneration &+= 1
        guard catalogRefreshTask == nil,
              let key = currentCatalogLoadKey() else { return }
        _ = startCatalogRefresh(key: key)
    }

    private func clearLiveConnectionProjection() {
        noticeCenter.dismissAll()
        sessionCatalog.markDisconnected()
        if let profile = profiles.selected {
            let retained = sessionCatalog.sessions.map {
                $0.withGatewaySource(id: profile.id, label: profile.label)
            }
            if !retained.isEmpty || dashboardSessionsByProfile[profile.id] == nil {
                dashboardSessionsByProfile[profile.id] = retained
            }
            dashboardStatesByProfile[profile.id] = .stale
        }
        dashboardPresentationRevision &+= 1
    }

    private func reconcileSelection() {
        defaultWorkspace = UserDefaults.standard.string(forKey: "defaultWorkspace.v1")
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
        presentError(error)
    }

    private func loadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        let value = await cache.load(profileID: profileID)
        guard admitsLifecycle(admission), profiles.selected?.id == profileID else { return }
        sessionCatalog.installCached(value.sessions)
        reconcileSelection()
        installSelectedDashboardCatalog()
    }

    private func scheduleCacheCheckpoint() {
        guard let profileID = profiles.selected?.id else { return }
        cacheCheckpointGeneration &+= 1
        pendingCacheCheckpoint = CacheCheckpoint(
            profileID: profileID,
            generation: cacheCheckpointGeneration,
            sessions: sessions
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
                    sessions: checkpoint.sessions
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

extension AppModel: DashboardGatewayConnectionPoolDelegate {
    func dashboardPoolAutomationChanged(profileID: String) {
        automationCatalog.invalidate(profileID: profileID)
    }

    func dashboardPoolNotificationInboxChanged(profileID: String) {
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else { return }
        Task { @MainActor [weak self] in await self?.refreshNotificationInbox(profile: profile) }
    }

    func dashboardPoolDidUpdate(
        profileID: String,
        sessions: [SessionSummary],
        state: DashboardServerConnectionState
    ) {
        // Once a profile becomes focused, the lifecycle/catalog owner is the
        // only authority allowed to publish its dashboard rows. A delayed pool
        // stop callback must not erase that newly authoritative projection.
        guard profileID != profiles.selected?.id,
              profiles.profiles.contains(where: { $0.id == profileID }) else { return }
        if dashboardStatesByProfile[profileID] != state {
            automationCatalog.invalidate(profileID: profileID)
        }
        let existingCount = dashboardSessionsByProfile[profileID]?.count ?? 0
        if DashboardProjectionRetentionPolicy.retainsExistingBucket(
            profileExists: true,
            existingSessionCount: existingCount,
            incomingSessionCount: sessions.count,
            state: state
        ) {
            guard dashboardStatesByProfile[profileID] != state else { return }
            dashboardStatesByProfile[profileID] = state
            dashboardPresentationRevision &+= 1
            return
        }
        guard dashboardSessionsByProfile[profileID] != sessions
            || dashboardStatesByProfile[profileID] != state else { return }
        dashboardSessionsByProfile[profileID] = sessions
        dashboardStatesByProfile[profileID] = state
        dashboardPresentationRevision &+= 1
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
        revision: Int,
        operationID: String?
    ) {
        guard ownsPresentation(target) else { return }
        if action == .native {
            if let operationID,
               extensionEditorOperationReceipts[target]?.contains(operationID) == true {
                extensionEditorOperationReceipts[target]?.removeAll { $0 == operationID }
                return
            }
            if let scope = composerDrafts.scope(for: target), composerDrafts.text(for: scope) == fullText {
                return
            }
        }
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

    func sessionPresentationStoreDidPublishSnapshot(
        _ snapshot: SessionSnapshot,
        target: SessionPresentationTarget
    ) {
        guard snapshot.sessionId == target.sessionID else { return }
        composerDrafts.reconcileSubmission(
            target: target,
            canonicalTranscript: snapshot.transcript,
            queuedMessages: snapshot.displayedQueuedMessages
        )
    }

    func sessionPresentationStoreDidFailOperation(
        operationID: String,
        target: SessionPresentationTarget
    ) {
        composerDrafts.failOperation(operationID, target: target)
    }

    func sessionPresentationStorePostNotice(
        _ message: String,
        replacing key: InAppNoticeKey?,
        role: InAppNoticeCenter.Role,
        scope: InAppNoticeScope?
    ) {
        let lifetime: InAppNoticeCenter.Lifetime = if key == .sessionCatchUp {
            .automatic(.seconds(12))
        } else if role == .error {
            .automatic(.seconds(8))
        } else if role == .warning {
            .automatic(.seconds(6))
        } else {
            .standard
        }
        postNotice(
            message,
            replacing: key,
            role: role,
            lifetime: lifetime,
            scope: scope ?? .app,
            priority: role == .error ? .high : .normal
        )
    }

    func sessionPresentationStoreRemoveNotice(_ key: InAppNoticeKey, scope: InAppNoticeScope?) {
        removeNotice(key, scope: scope)
    }

    func sessionPresentationStoreRetireNoticeScope(_ scope: InAppNoticeScope) {
        noticeCenter.retire(scope: scope)
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
        if let message { presentError(message) }
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
        diagnosticsAreReady = false
        invalidateSessionConnectionOwnership()
    }

    func lifecycleBeginReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission
    ) {
        guard admitsLifecycle(admission) else { return }
        reconciliationAggregateAdmission = admission
        isReconcilingForeground = true
    }

    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    ) {
        guard reconciliationAggregateAdmission == admission else { return }
        reconciliationAggregateAdmission = nil
        isReconcilingForeground = false
        if succeeded { foregroundReconciliationGeneration &+= 1 }
    }

    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {
        guard admitsLifecycle(admission) else { return }
        adoptConnectedGatewayIdentity()
        async let authResume: Void = providerAuth.resumeAuthIfNeeded()
        async let sessionLoad = refreshSessions()
        async let providerLoad = refreshProviders(target: .global)
        async let settingLoad = refreshSettings(target: .global)
        async let deviceLoad = refreshDevices()
        let sessionOutcome = await sessionLoad
        _ = await (authResume, providerLoad, settingLoad, deviceLoad)
        guard admitsLifecycle(admission) else { return }
        if sessionOutcome == .transportFailure {
            lifecycle.noteProjectionFailure(admission)
            return
        }
        reconcileDashboardConnections()
        removeNotice(.gatewayRestart)
        diagnosticsReadinessGeneration &+= 1
        diagnosticsAreReady = true
    }

    func lifecycleRestoreMountedPresentation(
        admission: GatewayLifecycleCoordinator.Admission
    ) async -> Bool {
        guard admitsLifecycle(admission) else { return true }
        let mountedTarget = sessionPresentation.mountedTarget
        let restored = await restoreMountedPresentationAfterReconnect()
        guard admitsLifecycle(admission), sessionPresentation.mountedTarget == mountedTarget else {
            // A route replacement owns the newer presentation; its late
            // reconnect result must not poison the lifecycle generation.
            return true
        }
        if let mountedTarget, !sessionPresentation.owns(mountedTarget) { return true }
        return restored
    }

    func lifecycleReattachTerminals(
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        await terminal.reattach(admission: admission)
    }

    func lifecycleReconcileForeground(
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws {
        lifecycleBeginReconciliationAggregate(admission: admission)
        var completed = false
        defer {
            lifecycleCompleteReconciliationAggregate(
                admission: admission,
                succeeded: completed
            )
        }
        try await client.ensureResponsive()
        try requireLifecycle(admission)
        async let authResume: Void = providerAuth.resumeAuthIfNeeded()
        async let catalog = refreshSessions()
        let mountedTarget = sessionPresentation.mountedTarget
        let mountedRestored = await sessionPresentation.reconnectMountedPresentation()
        try requireLifecycle(admission)
        guard sessionPresentation.mountedTarget == mountedTarget else {
            // The mounted route changed while this foreground pass was away;
            // the newer presentation owns reconciliation.
            return
        }
        if let mountedTarget, !sessionPresentation.owns(mountedTarget) { return }
        guard mountedRestored else {
            throw GatewayFailure(
                code: "projection_unavailable",
                message: "The mounted conversation could not be reconciled after returning to the foreground.",
                retryable: true,
                details: nil
            )
        }
        await terminal.reattach(admission: admission)
        _ = await authResume
        let outcome = await catalog
        if outcome == .transportFailure {
            throw GatewayFailure(
                code: "disconnected",
                message: "The Mac gateway did not provide a fresh session catalog.",
                retryable: true,
                details: nil
            )
        }
        reconcileDashboardConnections()
        try requireLifecycle(admission)
        // Mounted restoration and catalog refresh jointly publish the next
        // entrance-suppression generation.
        completed = true
        diagnosticsReadinessGeneration &+= 1
        diagnosticsAreReady = true
    }

    func lifecycleRetireProjection(final: Bool) async {
        diagnosticsAreReady = false
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
        dashboardConnections.retire()
        await dashboardConnections.waitForRetirement()
        invalidateSessionConnectionOwnership()
        chatMedia.removeAll()
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
