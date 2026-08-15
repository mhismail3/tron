import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    typealias SessionSnapshotInstallMode = SessionSnapshotInstallationMode
    typealias ConnectionState = GatewayConnectionState

    struct PendingAttachment: Identifiable, Hashable {
        let id: String
        let name: String
        let mimeType: String
        let size: Int
        let previewData: Data?
    }

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

    struct EditorRequest: Identifiable, Hashable {
        typealias Action = SessionEditorAction
        let sessionId: String
        let presentationGeneration: Int
        let revision: Int
        let action: Action
        let text: String
        let fullText: String
        var id: String { "\(sessionId):\(presentationGeneration):\(revision)" }
    }

    typealias SessionOpenResponse = GatewaySessionOpenResponse
    typealias PairingCommit = GatewayPairingCommit
    typealias ProfileTokenLookup = GatewayProfileTokenLookup

    private let lifecycle: GatewayLifecycleCoordinator
    var client: GatewayClient { lifecycle.client }
    var profiles: GatewayProfileStore { lifecycle.profiles }
    private let cache: SnapshotCache
    private let clock: MonotonicClock
    private let uuidSource: UUIDSource
    private let performanceSignposts: any PerformanceSignposting
    private let mutationExecutor: ConfirmedMutationExecutor
    private let sessionMutations: SessionMutationService
    private let sessionImports: SessionImportCoordinator
    private let settingsTrust: SettingsTrustCoordinator
    private let providerAuth: ProviderAuthCoordinator

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
    var packageInvalidationGeneration = 0
    var customModelInvalidationGeneration = 0
    var trustRevision: Int { settingsTrust.trustRevision }
    var pairedDevices: [PairedDevice] = []
    var legacyImportAvailable = false
    var legacyImportedCount = 0
    var workspace: WorkspaceListing?
    var defaultWorkspace: String?
    private var pendingAttachmentsByTarget = PresentationOwnedStore<
        SessionPresentationTarget,
        [PendingAttachment]
    >()
    var authPrompt: AuthPromptState? { providerAuth.prompt }
    var authEvent: AuthEventState? { providerAuth.event }
    private var editorRequestByTarget = PresentationOwnedStore<
        SessionPresentationTarget,
        EditorRequest
    >()
    private var noticeStore = GlobalNoticeStore()
    var latestNotice: String? { noticeStore.latest }
    var lastError: String?
    var onboardingError: String?
    var context: JSONValue? { sessionPresentation.context }
    var sessionTree: [SessionTreeNode] { sessionPresentation.sessionTree }
    var loadingEarlierTranscript: Bool { sessionPresentation.loadingEarlierTranscript }
    var commands: [CommandInfo] { sessionPresentation.commands }
    var resources: JSONValue? { sessionPresentation.resources }
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

    private var eventTask: Task<Void, Never>?
    private var packageLoadGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
    private var packageUpdateGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
    private var customModelLoadGenerationByTarget: [CustomModelTarget: Int] = [:]
    private var deviceLoadGeneration = 0
    private var legacyImportLoadGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var hiddenSessionIDs: Set<String> = []
    private var terminalCleanupGeneration = 0
    private var terminalCleanupTasks: [Int: Task<Void, Never>] = [:]
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
        sessionImportUpload: SessionImportUpload? = nil
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
        self.settingsTrust = settingsTrust
        self.providerAuth = providerAuth
        self.sessionPresentation = SessionPresentationStore(
            client: client,
            performanceSignposts: performanceSignposts
        )
        self.cache = cache
        self.clock = clock
        self.uuidSource = uuidSource
        self.performanceSignposts = performanceSignposts
        #if HOSTED_TEST
        if ProcessInfo.processInfo.arguments.contains("--tron-reset-ui-test-state") {
            for profile in profiles.profiles { profiles.remove(profile) }
            UserDefaults.standard.removeObject(forKey: "tronSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "piSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "defaultWorkspace.v1")
        }
        #endif
        lifecycle.delegate = self
        sessionPresentation.delegate = self
        settingsTrust.delegate = self
        providerAuth.delegate = self
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
    }

    func installHostedAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        sessionPresentation.installHostedAuthoritativeSnapshot(snapshot)
    }

    func installHostedPendingAttachments(
        _ attachments: [PendingAttachment],
        for target: SessionPresentationTarget
    ) {
        guard ownsPresentation(target) else { return }
        pendingAttachmentsByTarget[target] = attachments.isEmpty ? nil : attachments
    }

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

    func presentationTarget(for sessionID: String) -> SessionPresentationTarget? {
        sessionPresentation.presentationTarget(for: sessionID)
    }

    func ownsPresentation(_ target: SessionPresentationTarget) -> Bool {
        sessionPresentation.owns(target)
    }

    func revokePresentationIntake(_ target: SessionPresentationTarget) {
        sessionPresentation.revokeIntake(target)
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
        await lifecycle.start()
    }

    func becameActive() {
        lifecycle.becameActive()
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
        sessionCatalog.invalidateLoads()
        workspaceLoadGeneration &+= 1
        deviceLoadGeneration &+= 1
        legacyImportLoadGeneration &+= 1
        packageLoadGenerationByTarget = packageLoadGenerationByTarget.mapValues { $0 &+ 1 }
        packageUpdateGenerationByTarget = packageUpdateGenerationByTarget.mapValues { $0 &+ 1 }
        customModelLoadGenerationByTarget = customModelLoadGenerationByTarget.mapValues { $0 &+ 1 }
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
        packageInventoryByTarget.removeAll()
        packageUpdatesByTarget.removeAll()
        customModelsByTarget.removeAll()
        lastError = nil
        onboardingError = nil
        pendingAttachmentsByTarget = .init()
        editorRequestByTarget = .init()
        clearLiveConnectionProjection()
    }

    func switchGateway(_ profile: GatewayProfile) async {
        await lifecycle.switchGateway(profile)
    }

    func forgetCurrentGateway() async {
        if await lifecycle.forgetCurrentGateway() {
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
        let loadAdmission = sessionCatalog.beginLoad()
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
                guard sessionCatalog.admits(loadAdmission) else { return false }
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
            guard sessionCatalog.publishAuthoritative(all, admission: loadAdmission) else {
                return false
            }
            reconcileSelection()
            saveCache()
            return true
        } catch {
            guard sessionCatalog.admits(loadAdmission) else { return false }
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
        let response: Response = try await mutationExecutor.perform(method: "device.revoke", commandID: commandID) {
            try await client.request("device.revoke", params)
        }
        if response.revoked {
            pairedDevices.removeAll { $0.id == id }
            if let profile = profiles.selected, profile.deviceId == id,
               await lifecycle.forget(profile: profile) {
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

    func createSession(cwd: String) async throws -> String {
        let sessionID = try await sessionMutations.createSession(cwd: cwd)
        defaultWorkspace = cwd
        UserDefaults.standard.set(cwd, forKey: "defaultWorkspace.v1")
        await refreshSessions()
        return sessionID
    }

    /// Starts a new mounted chat presentation. Unlike reconnect synchronization,
    /// this always installs a fresh authoritative bounded tail and never carries
    /// an explicitly paged prefix across navigation lifetimes.
    func openSessionPresentation(_ id: String) async throws -> Int {
        try await sessionPresentation.open(id)
    }

    func closeSessionPresentation(_ id: String, generation: Int) async {
        let target = SessionPresentationTarget(sessionID: id, generation: generation)
        pendingAttachmentsByTarget.removeValue(for: target)
        editorRequestByTarget.removeValue(for: target)
        await sessionPresentation.close(target)
    }

    func loadEarlierTranscript(sessionID: String, presentationGeneration: Int) async {
        await sessionPresentation.loadEarlier(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration
        )
    }

    private func invalidateSessionConnectionOwnership() {
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
        try await sessionMutations.prompt(
            text,
            sessionID: sessionID,
            uploadIDs: uploadIDs,
            behavior: behavior
        )
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
        let data = try await client.blob(id: response.blobId).0
        guard sessionPresentation.ownsInstalledSubscription(
            sessionID: sessionID,
            token: subscriptionToken
        ) else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "TronExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: response.name, directoryHint: .notDirectory)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func deleteSession(_ id: String) async throws {
        await sessionPresentation.closeSubscriptionIfInstalled(sessionID: id)
        try await sessionMutations.delete(sessionID: id)
        sessionPresentation.remove(sessionID: id)
        sessionCatalog.remove(id)
        saveCache()
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
        _ = try await mutationExecutor.performValue(method: method, commandID: commandID) {
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
            return try await self.mutationExecutor.performValue(method: method, commandID: commandID) {
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
        let response: Response = try await mutationExecutor.perform(method: "gateway.restart", commandID: commandID) {
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
        let response: Response = try await mutationExecutor.perform(method: "filesystem.mkdir", commandID: commandID) {
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
        try await sessionMutations.answerInteraction(
            interactionID: interaction.id,
            sessionID: sessionID,
            value: value,
            cancelled: cancelled
        )
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
        let admission = lifecycle.admission
        let subscriptionToken = sessionPresentation.installedSubscriptionToken(for: sessionID)
        guard let admission,
              terminalState.owns(intent),
              subscriptionToken != nil else {
            throw GatewayFailure(code: "sync_failed", message: "Open the session before listing terminals.", retryable: true, details: nil)
        }
        struct Params: Codable, Sendable { let sessionId: String }
        struct Response: Decodable, Sendable { let terminals: [TerminalSummary] }
        let request = Task { try await client.request("terminal.list", Params(sessionId: sessionID)) as Response }
        let response = try await request.value
        try requireConnection(admission)
        guard terminalState.owns(intent),
              sessionPresentation.installedSubscriptionToken(for: sessionID) == subscriptionToken,
              response.terminals.allSatisfy({ $0.sessionId == sessionID }) else { throw CancellationError() }
        terminalState.installInventory(response.terminals, sessionID: sessionID)
        return response.terminals
    }

    func openTerminal(
        intent: TerminalPresentationIntent,
        columns: Int,
        rows: Int
    ) async throws -> TerminalSummary {
        guard let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
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
                try await mutationExecutor.perform(method: "terminal.open", commandID: commandID) {
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
            let currentAdmission = lifecycle.admission
            let currentConnectionID = currentAdmission?.connectionID
            switch TerminalCoordinator.openResponseDisposition(
                requestLifecycleGeneration: admission.generation,
                requestConnectionID: connectionID,
                currentLifecycleGeneration: currentAdmission?.generation,
                currentConnectionID: currentConnectionID
            ) {
            case .install:
                break
            case .reattach:
                // Receipt resolution may legitimately cross a reconnect within
                // one profile lifecycle. Establish terminal event ownership on
                // the decisive current connection before publishing replay.
                terminalState.finish(lease)
                guard terminalState.owns(intent), let currentConnectionID else {
                    if let currentConnectionID {
                        scheduleTerminalDetachIfUnowned(TerminalDetachClaim(
                            terminalID: response.terminal.id,
                            connectionID: currentConnectionID
                        ))
                    }
                    throw CancellationError()
                }
                let terminal = try await attachTerminal(
                    response.terminal.id,
                    after: 0,
                    intent: intent
                )
                return (terminal, .none)
            case .discard:
                terminalState.finish(lease)
                throw CancellationError()
            }
            guard !Task.isCancelled,
                  admitsLifecycle(admission),
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
        guard let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
              let lease = terminalState.beginAttachment(
                terminalID: id,
                intent: intent,
                connectionID: connectionID
              ) else { throw CancellationError() }
        return try await performTerminalAttach(
            id,
            after: after,
            lease: lease,
            admission: admission
        )
    }

    private func performTerminalAttach(
        _ id: String,
        after: Int,
        lease: TerminalAttachmentLease,
        admission: GatewayLifecycleCoordinator.Admission
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
                  admitsLifecycle(admission),
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
        guard let admission = lifecycle.admission,
              admission.connectionID == claim.connectionID else { return }
        terminalCleanupGeneration &+= 1
        let cleanupGeneration = terminalCleanupGeneration
        terminalCleanupTasks[cleanupGeneration] = Task { [weak self] in
            guard let self else { return }
            defer { self.terminalCleanupTasks.removeValue(forKey: cleanupGeneration) }
            guard self.admitsLifecycle(admission),
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
        let _: Response = try await mutationExecutor.perform(method: "terminal.write", commandID: identity) {
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
        let _: Response = try await mutationExecutor.perform(method: "terminal.resize", commandID: commandID) {
            try await client.request("terminal.resize", params)
        }
    }

    func terminateTerminal(_ id: String, intent: TerminalPresentationIntent) async throws {
        guard terminalState.owns(intent) else { throw CancellationError() }
        struct Params: Codable { let terminalId, commandId: String }
        struct Response: Codable { let terminated: Bool }
        let commandID = uuidSource.next().uuidString
        let params = Params(terminalId: id, commandId: commandID)
        let _: Response = try await mutationExecutor.perform(method: "terminal.terminate", commandID: commandID) {
            try await client.request("terminal.terminate", params)
        }
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
            saveCache()
        }
    }

    private func scheduleSessionListRefresh() {
        guard let admission = lifecycle.admission else { return }
        refreshTask?.cancel()
        let clock = self.clock
        refreshTask = Task { [weak self] in
            do { try await clock.sleep(.milliseconds(150)) }
            catch { return }
            guard let self, self.admitsLifecycle(admission) else { return }
            await self.refreshSessions()
            guard self.admitsLifecycle(admission) else { return }
            self.refreshTask = nil
        }
    }

    private func clearLiveConnectionProjection() {
        noticeStore.removeAll()
        sessionCatalog.markDisconnected()
        terminalState.clear()
    }

    private func reconcileTerminal(_ terminalID: String) {
        guard let admission = lifecycle.admission,
              let connectionID = admission.connectionID,
              let lease = terminalState.beginReconciliation(
                terminalID: terminalID,
                connectionID: connectionID
              ) else { return }
        let after = terminalState.replay(for: terminalID).chunks.last?.sequence ?? 0
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.performTerminalAttach(
                terminalID,
                after: after,
                lease: lease,
                admission: admission
            )
        }
    }

    private func reattachTerminals(
        admission: GatewayLifecycleCoordinator.Admission
    ) async {
        guard admitsLifecycle(admission),
              let connectionID = admission.connectionID else { return }
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
                admission: admission
            )
        }
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

    private func saveCache() {
        guard let id = profiles.selected?.id else { return }
        let sessions = sessions
        let values = sessionPresentation.snapshot.map { [$0] } ?? []
        Task { await cache.save(profileID: id, sessions: sessions, snapshots: values) }
    }

}

extension AppModel: SessionPresentationStoreDelegate {
    func sessionPresentationStoreDidUpdateSummary(_ snapshot: SessionSnapshot) {
        sessionCatalog.update(from: snapshot)
    }

    func sessionPresentationStoreDidRequestCatalogRefresh() {
        scheduleSessionListRefresh()
    }

    func sessionPresentationStoreDidPublishEditorRequest(
        target: SessionPresentationTarget,
        action: EditorRequest.Action,
        text: String,
        fullText: String,
        revision: Int
    ) {
        guard ownsPresentation(target) else { return }
        editorRequestByTarget[target] = .init(
            sessionId: target.sessionID,
            presentationGeneration: target.generation,
            revision: revision,
            action: action,
            text: text,
            fullText: fullText
        )
    }

    func sessionPresentationStoreDidOpen(_ target: SessionPresentationTarget) {
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
        saveCache()
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
        await reattachTerminals(admission: admission)
    }

    func lifecycleReconcileForeground(
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws {
        try await client.ensureResponsive()
        try requireLifecycle(admission)
        guard await refreshSessions(surfacingErrors: false) else {
            throw GatewayFailure(
                code: "disconnected",
                message: "The Mac gateway connection is resuming.",
                retryable: true,
                details: nil
            )
        }
        try requireLifecycle(admission)
        if !(await sessionPresentation.reconnectMountedPresentation()) {
            throw GatewayFailure(
                code: "sync_failed",
                message: "The live session is resuming.",
                retryable: true,
                details: nil
            )
        }
        try requireLifecycle(admission)
        await reattachTerminals(admission: admission)
        try requireLifecycle(admission)
    }

    func lifecycleRetireProjection(final: Bool) async {
        let refresh = refreshTask
        let events = final ? eventTask : nil
        let terminalCleanup = Array(terminalCleanupTasks.values)
        refreshTask = nil
        terminalCleanupTasks.removeAll()
        refresh?.cancel()
        terminalCleanup.forEach { $0.cancel() }
        if final {
            events?.cancel()
            eventTask = nil
        }

        invalidateProfileScopedLoads()
        invalidateSessionConnectionOwnership()
        clearGatewayProjection()

        await refresh?.value
        for task in terminalCleanup { await task.value }
        await events?.value
    }

    func lifecycleSurface(_ error: Error) {
        surface(error)
    }
}
