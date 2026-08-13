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

    struct EditorRequest: Identifiable, Hashable {
        enum Action: String { case set, paste }
        let sessionId: String
        let revision: Int
        let action: Action
        let text: String
        let fullText: String
        var id: String { "\(sessionId):\(revision)" }
    }

    private struct SessionOpenResponse: Decodable { let session: SessionSnapshot; let syncToken: String }
    private struct SessionMutationResponse: Codable { let sessionId: String }
    private struct CommandStatusParams: Codable { let method, commandId: String }
    private struct CommandStatusResponse: Decodable { let status: String; let result: JSONValue? }

    let client: GatewayClient
    let profiles: GatewayProfileStore
    private let cache: SnapshotCache

    var connectionState: ConnectionState = .unpaired
    /// False only while the first launch credential/connection decision is
    /// unresolved. The UI must not infer "unpaired" from the temporary default.
    var hasResolvedLaunchState = false
    var gatewayInfo: GatewayInfo?
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
    var settingsRevision = 0
    var providerRevision = 0
    var packageRevision = 0
    var customModelRevision = 0
    var trustRevision = 0
    var providers: [ProviderSummary] = []
    var models: [ModelSummary] = []
    var pairedDevices: [PairedDevice] = []
    var legacyImportAvailable = false
    var legacyImportedCount = 0
    var workspace: WorkspaceListing?
    var defaultWorkspace: String?
    var pendingAttachments: [PendingAttachment] = []
    var authPrompt: AuthPromptState?
    var authEvent: AuthEventState?
    var editorRequest: EditorRequest?
    var notifications: [String] = []
    var lastError: String?
    var onboardingError: String?
    var settings: JSONValue?
    var context: JSONValue?
    var sessionTree: [SessionTreeNode] = []
    var loadingEarlierTranscript = false
    private(set) var authoritativeSessionIDs: Set<String> = []
    var commands: [CommandInfo] = []
    var resources: JSONValue?
    var packageState: PackageInventory?
    var packageUpdates: [PackageUpdate] = []
    var customModels: JSONValue?
    var terminals: [TerminalSummary] = []
    var terminalChunks: [String: [TerminalChunk]] = [:]
    var terminalExited: Set<String> = []
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
    private var reconnectTask: Task<Void, Never>?
    private var foregroundReconciliationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var subscribedSessionID: String?
    private var sessionEventSynchronizer = SessionEventSynchronizer()
    private var pendingAuthoritativeResyncSessionIDs: Set<String> = []
    private var pendingBranchReplacementSessionIDs: Set<String> = []
    private var hiddenSessionIDs: Set<String> = []
    private var locallyCreatedUnindexedSessionIDs: Set<String> = []
    private var liveSessionSummaryUpdates: [String: SessionSummaryUpdate] = [:]
    private var attachedTerminalIDs: Set<String> = []
    private var reconcilingTerminalIDs: Set<String> = []
    private var workspaceLoadGeneration = 0
    private var presentationOpenGeneration = 0
    private var mountedPresentationGenerationBySession: [String: Int] = [:]

    init(
        client: GatewayClient = GatewayClient(),
        profiles: GatewayProfileStore = GatewayProfileStore(),
        cache: SnapshotCache = SnapshotCache()
    ) {
        self.client = client
        self.profiles = profiles
        self.cache = cache
        #if HOSTED_TEST
        if ProcessInfo.processInfo.arguments.contains("--tron-reset-ui-test-state") {
            for profile in profiles.profiles { profiles.remove(profile) }
            UserDefaults.standard.removeObject(forKey: "tronSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "piSetupComplete.v1")
            UserDefaults.standard.removeObject(forKey: "defaultWorkspace.v1")
        }
        #endif
        eventTask = Task { [weak self, client] in
            for await event in client.events { await self?.handle(event) }
        }
    }

    var selectedSnapshot: SessionSnapshot? {
        selectedSessionID.flatMap { snapshots[$0] }
    }

    func authoritativeSnapshot(for sessionID: String) -> SessionSnapshot? {
        guard authoritativeSessionIDs.contains(sessionID) else { return nil }
        return snapshots[sessionID]
    }

    func presentationGeneration(for sessionID: String) -> Int? {
        mountedPresentationGenerationBySession[sessionID]
    }

    var selectedSessionStructureRevision: Int {
        selectedSessionID.flatMap { sessionStructureRevisions[$0] } ?? 0
    }

    var selectedSessionContextRevision: Int {
        selectedSessionID.flatMap { sessionContextRevisions[$0] } ?? 0
    }

    var selectedSessionResourceRevision: Int {
        selectedSessionID.flatMap { sessionResourceRevisions[$0] } ?? 0
    }

    var configuredDefaultModel: ModelRef? {
        guard let model = settings?.objectValue?["effective"]?.objectValue?["defaultModel"]?.objectValue,
              let provider = model["provider"]?.stringValue,
              let id = model["id"]?.stringValue else { return nil }
        return ModelRef(provider: provider, id: id)
    }

    var preferredAvailableModel: ModelRef? {
        let available = models.filter(\.available)
        return available.first(where: { $0.provider == "openai-codex" && $0.id == "gpt-5.6-sol" })?.ref
            ?? available.first?.ref
    }

    var visibleSessions: [SessionSummary] { sessions.filter { !hiddenSessionIDs.contains($0.id) } }

    func start() async {
        guard connectionState != .connecting, connectionState != .connected, connectionState != .reconnecting else { return }
        guard let profile = profiles.selected, let token = profiles.token(for: profile) else {
            connectionState = .unpaired
            hasResolvedLaunchState = true
            return
        }
        await loadCache(profileID: profile.id)
        await connect(profile: profile, token: token)
        hasResolvedLaunchState = true
    }

    func becameActive() {
        guard connectionState == .connected else {
            if connectionState != .connecting, connectionState != .reconnecting { scheduleReconnect(immediate: true) }
            return
        }
        // Scene activation can be delivered more than once while system network
        // paths are also resuming. One reconciliation owns that boundary so two
        // session.open handshakes cannot race each other.
        guard foregroundReconciliationTask == nil else { return }
        foregroundReconciliationTask = Task { [weak self] in
            await self?.reconcileForegroundState()
            self?.foregroundReconciliationTask = nil
        }
    }

    func pair(_ invitation: PairingInvitation) async throws {
        connectionState = .connecting
        let name = UIDevice.current.name
        let (profile, token) = try await GatewayPairer.pair(invitation, deviceName: name)
        try profiles.save(profile, token: token)
        await connect(profile: profile, token: token)
        hasResolvedLaunchState = true
    }

    func switchGateway(_ profile: GatewayProfile) async {
        guard let token = profiles.token(for: profile) else {
            lastError = "This gateway no longer has a Keychain token. Pair it again."
            return
        }
        profiles.select(profile)
        sessions = []
        snapshots = [:]
        authoritativeSessionIDs = []
        selectedSessionID = nil
        subscribedSessionID = nil
        clearLiveConnectionState()
        await loadCache(profileID: profile.id)
        await connect(profile: profile, token: token)
    }

    func forgetCurrentGateway() {
        if let profile = profiles.selected { profiles.remove(profile) }
        Task { await client.close() }
        gatewayInfo = nil
        sessions = []
        snapshots = [:]
        authoritativeSessionIDs = []
        selectedSessionID = nil
        subscribedSessionID = nil
        clearLiveConnectionState()
        setupComplete = false
        connectionState = .unpaired
        hasResolvedLaunchState = true
    }

    private func connect(profile: GatewayProfile, token: String) async {
        connectionState = .connecting
        do {
            gatewayInfo = try await client.connect(profile: profile, token: token)
            subscribedSessionID = nil
            sessionEventSynchronizer.reset()
            pendingAuthoritativeResyncSessionIDs.removeAll()
            pendingBranchReplacementSessionIDs.removeAll()
            reconnectTask?.cancel()
            reconnectTask = nil
            await refreshAll()
            await reattachTerminals()
            connectionState = .connected
        } catch let failure as GatewayFailure where failure.code == "unauthenticated" {
            connectionState = .unauthorized
            lastError = failure.message
        } catch {
            connectionState = .offline(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard profiles.selected != nil, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .seconds(2)) }
            var delay = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                self.connectionState = .reconnecting
                do {
                    self.gatewayInfo = try await self.client.reconnect()
                    self.subscribedSessionID = nil
                    self.sessionEventSynchronizer.reset()
                    self.pendingAuthoritativeResyncSessionIDs.removeAll()
                    self.pendingBranchReplacementSessionIDs.removeAll()
                    await self.refreshAll()
                    await self.reattachTerminals()
                    self.connectionState = .connected
                    self.reconnectTask = nil
                    return
                } catch let failure as GatewayFailure where failure.code == "unauthenticated" {
                    self.connectionState = .unauthorized
                    self.lastError = failure.message
                    self.reconnectTask = nil
                    return
                } catch {
                    self.connectionState = .offline(error.localizedDescription)
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 1.7, 15)
                }
            }
        }
    }

    private func reconcileForegroundState() async {
        do {
            try await client.ensureResponsive()
            guard await refreshSessions(surfacingErrors: false) else {
                throw GatewayFailure(code: "disconnected", message: "The Mac gateway connection is resuming.", retryable: true, details: nil)
            }
            if let selectedSessionID, !(await synchronizeSession(selectedSessionID)) {
                throw GatewayFailure(code: "sync_failed", message: "The live session is resuming.", retryable: true, details: nil)
            }
            await reattachTerminals()
        } catch is CancellationError {
            return
        } catch {
            connectionState = .reconnecting
            subscribedSessionID = nil
            sessionEventSynchronizer.reset()
            pendingAuthoritativeResyncSessionIDs.removeAll()
            pendingBranchReplacementSessionIDs.removeAll()
            reconnectTask?.cancel()
            reconnectTask = nil
            scheduleReconnect(immediate: true)
        }
    }

    func refreshAll(projectSessionID: String? = nil, projectCWD: String? = nil, useSelectedProject: Bool = true) async {
        await refreshSessions()
        let effectiveSessionID = projectSessionID ?? (useSelectedProject ? selectedSessionID : nil)
        let effectiveCWD = projectCWD ?? (useSelectedProject ? selectedSnapshot?.cwd : nil)
        async let providerLoad: Void = refreshProviders(sessionID: effectiveSessionID, useSelectedProject: false)
        async let settingLoad: Void = refreshSettings(cwd: effectiveCWD, useSelectedProject: false)
        async let deviceLoad: Void = refreshDevices()
        _ = await (providerLoad, settingLoad, deviceLoad)
        if let effectiveSessionID { try? await openSession(effectiveSessionID) }
    }

    @discardableResult
    func refreshSessions(surfacingErrors: Bool = true) async -> Bool {
        struct Params: Encodable { let cursor: String?; let limit: Int }
        struct Response: Decodable { let sessions: [SessionSummary]; let nextCursor: String?; let listRevision: Int }
        do {
            var all: [SessionSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            var expectedRevision: Int?
            repeat {
                let response: Response = try await client.request(
                    "session.list",
                    Params(cursor: cursor, limit: 200)
                )
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
            if surfacingErrors { surface(error) }
            return false
        }
    }

    func refreshDevices() async {
        struct Response: Decodable { let devices: [PairedDevice] }
        do {
            let response: Response = try await client.request("device.list", EmptyParams())
            pairedDevices = response.devices
        } catch { surface(error) }
    }

    func revokeDevice(_ id: String) async throws {
        struct Params: Codable { let deviceId: String; let commandId: String }
        struct Response: Codable { let revoked: Bool }
        let commandID = UUID().uuidString
        let params = Params(deviceId: id, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "device.revoke", commandId: commandID) {
            try await client.request("device.revoke", params)
        }
        if response.revoked {
            pairedDevices.removeAll { $0.id == id }
            if let profile = profiles.selected, profile.deviceId == id {
                profiles.remove(profile)
                connectionState = .unpaired
                await client.close()
            }
        }
    }

    func inspectLegacyImport() async {
        struct Response: Decodable { let available: Bool; let importedCount: Int }
        do {
            let response: Response = try await client.request("legacy.inspect", EmptyParams())
            legacyImportAvailable = response.available
            legacyImportedCount = response.importedCount
        } catch { surface(error) }
    }

    func importLegacySessions(port: Int = 9849) async throws {
        struct Params: Codable { let port: Int; let commandId: String }
        struct Response: Codable { let imported: Int; let skipped: Int }
        let commandID = UUID().uuidString
        let params = Params(port: port, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "legacy.import", commandId: commandID) {
            try await client.request("legacy.import", params, timeout: .seconds(600))
        }
        legacyImportedCount += response.imported
        notifications.append("Imported \(response.imported) legacy session\(response.imported == 1 ? "" : "s"); skipped \(response.skipped).")
        await refreshSessions()
    }

    func importSession(from url: URL, cwd: String) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let uploadID = try await client.upload(name: url.lastPathComponent, mimeType: "application/x-ndjson", data: data)
        struct Params: Codable { let uploadId, cwd, commandId: String }
        typealias Response = SessionMutationResponse
        await closeCurrentSubscription()
        let commandID = UUID().uuidString
        let params = Params(uploadId: uploadID, cwd: cwd, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.import", commandId: commandID) {
            try await client.request("session.import", params, timeout: .seconds(120))
        }
        selectedSessionID = response.sessionId
        guard await synchronizeSession(response.sessionId) else {
            throw GatewayFailure(code: "sync_failed", message: "Tron imported the session but could not synchronize it.", retryable: true, details: nil)
        }
        await refreshSessions()
    }

    func createSession(cwd: String) async throws {
        struct Params: Codable { let cwd: String; let commandId: String }
        typealias Response = SessionMutationResponse
        await closeCurrentSubscription()
        let commandID = UUID().uuidString
        let params = Params(cwd: cwd, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.create", commandId: commandID) {
            try await client.request("session.create", params, timeout: .seconds(60))
        }
        locallyCreatedUnindexedSessionIDs.insert(response.sessionId)
        selectedSessionID = response.sessionId
        guard await synchronizeSession(response.sessionId) else {
            throw GatewayFailure(code: "sync_failed", message: "Tron created the session but could not synchronize it.", retryable: true, details: nil)
        }
        defaultWorkspace = cwd
        UserDefaults.standard.set(cwd, forKey: "defaultWorkspace.v1")
        await refreshSessions()
    }

    /// Starts a new mounted chat presentation. Unlike reconnect synchronization,
    /// this always installs a fresh authoritative bounded tail and never carries
    /// an explicitly paged prefix across navigation lifetimes.
    func openSessionPresentation(_ id: String) async throws -> Int {
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
        mountedPresentationGenerationBySession[id] = generation
        Task { [weak self] in
            guard let self else { return }
            async let providerRefresh: Void = self.refreshProviders(sessionID: id, useSelectedProject: false)
            async let commandRefresh: Void = self.loadCommands(for: id)
            _ = await (providerRefresh, commandRefresh)
        }
        return generation
    }

    func closeSessionPresentation(_ id: String, generation: Int) async {
        guard mountedPresentationGenerationBySession[id] == generation else { return }
        mountedPresentationGenerationBySession[id] = nil
        authoritativeSessionIDs.remove(id)
        await closeSubscription(id, expectedPresentationGeneration: generation)
    }

    func openSession(_ id: String) async throws {
        if subscribedSessionID != id { await closeCurrentSubscription() }
        selectedSessionID = id
        if subscribedSessionID != id || snapshots[id] == nil {
            let synchronized = await synchronizeSession(id)
            guard synchronized, subscribedSessionID == id else {
                throw GatewayFailure(code: "sync_failed", message: "Tron could not synchronize this session.", retryable: true, details: nil)
            }
        }
        authoritativeSessionIDs.insert(id)
        async let providerRefresh: Void = refreshProviders()
        async let commandRefresh: Void = loadCommands()
        _ = await (providerRefresh, commandRefresh)
    }

    func loadEarlierTranscript(presentationGeneration: Int) async {
        guard !loadingEarlierTranscript,
              let sessionID = selectedSessionID,
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

    private func closeCurrentSubscription() async {
        guard let sessionID = subscribedSessionID else { return }
        await closeSubscription(sessionID)
    }

    private func closeSubscription(_ sessionID: String, expectedPresentationGeneration: Int? = nil) async {
        if let expectedPresentationGeneration,
           mountedPresentationGenerationBySession[sessionID] != nil,
           mountedPresentationGenerationBySession[sessionID] != expectedPresentationGeneration { return }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let closed: Bool }
        let _: Response? = try? await client.request("session.close", Params(sessionId: sessionID))
        if let expectedPresentationGeneration,
           mountedPresentationGenerationBySession[sessionID] != nil,
           mountedPresentationGenerationBySession[sessionID] != expectedPresentationGeneration { return }
        if subscribedSessionID == sessionID { subscribedSessionID = nil }
    }

    func send(_ text: String, behavior: String? = nil) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable {
            let sessionId: String
            let text: String
            let uploadIds: [String]
            let behavior: String?
            let commandId: String
        }
        struct Response: Codable { let operationId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, text: text, uploadIds: pendingAttachments.map(\.id), behavior: behavior, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "session.prompt", commandId: commandID) {
            try await client.request("session.prompt", params, as: Response.self, timeout: .seconds(15))
        }
        pendingAttachments.removeAll()
    }

    func abort(kind: String = "agent") async {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, kind, commandId: String }
        struct Response: Codable { let aborted: Bool }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, kind: kind, commandId: commandID)
        do {
            let _: Response = try await confirmedMutation(method: "session.abort", commandId: commandID) {
                try await client.request("session.abort", params, timeout: .seconds(30))
            }
        } catch { surface(error) }
    }

    func clearQueue() async throws -> SessionSnapshot.QueuedMessages {
        guard let sessionID = selectedSessionID else { return .init(steering: [], followUp: []) }
        struct Params: Codable { let sessionId, commandId: String }
        let commandID = UUID().uuidString
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

    func executeBash(_ command: String, excludeFromContext: Bool = false) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, command: String; let excludeFromContext: Bool; let commandId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, command: command, excludeFromContext: excludeFromContext, commandId: commandID)
        _ = try await confirmedMutationValue(method: "session.bash", commandId: commandID) {
            try await client.requestValue("session.bash", params, timeout: .seconds(300))
        }
    }

    func setModel(_ model: ModelRef) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, provider, modelId, commandId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, provider: model.provider, modelId: model.id, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.setModel", commandId: commandID) {
            try await client.request("session.setModel", params)
        }
    }

    func setThinking(_ level: String) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, level, commandId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, level: level, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.setThinking", commandId: commandID) {
            try await client.request("session.setThinking", params)
        }
    }

    func rename(_ name: String) async throws {
        guard let sessionID = selectedSessionID else { return }
        try await renameSession(sessionID, name: name)
    }

    func renameSession(_ sessionID: String, name: String) async throws {
        struct Params: Codable { let sessionId, name, commandId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, name: name, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.rename", commandId: commandID) {
            try await client.request("session.rename", params)
        }
    }

    func compact(instructions: String? = nil) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String; let instructions: String?; let commandId: String }
        struct Response: Codable { let compacted: Bool }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, instructions: instructions, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "session.compact", commandId: commandID) {
            try await client.request("session.compact", params, timeout: .seconds(300))
        }
    }

    func setTools(_ tools: [String]) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String; let tools: [String]; let commandId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, tools: tools, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.setTools", commandId: commandID) {
            try await client.request("session.setTools", params)
        }
    }

    @discardableResult
    func fork(entryID: String, position: String = "before") async throws -> String? {
        guard let sessionID = selectedSessionID else { return nil }
        struct Params: Codable { let sessionId, entryId, position, commandId: String }
        struct Response: Codable { let sessionId: String; let selectedText: String? }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, position: position, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.fork", commandId: commandID) {
            try await client.request("session.fork", params, timeout: .seconds(120))
        }
        selectedSessionID = response.sessionId
        subscribedSessionID = response.sessionId
        try await openSession(response.sessionId)
        if let selectedText = response.selectedText {
            editorRequest = .init(sessionId: response.sessionId, revision: Int(Date.now.timeIntervalSince1970 * 1_000), action: .set, text: selectedText, fullText: selectedText)
        }
        await refreshSessions()
        return response.selectedText
    }

    @discardableResult
    func navigate(entryID: String, summarize: Bool, instructions: String? = nil, replaceInstructions: Bool = false, label: String? = nil) async throws -> String? {
        guard let sessionID = selectedSessionID else { return nil }
        struct Params: Codable {
            let sessionId, entryId: String
            let summarize: Bool
            let instructions: String?
            let replaceInstructions: Bool
            let label: String?
            let commandId: String
        }
        struct Response: Codable { let editorText: String? }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, summarize: summarize, instructions: instructions, replaceInstructions: replaceInstructions, label: label, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.navigate", commandId: commandID) {
            try await client.request("session.navigate", params, timeout: .seconds(300))
        }
        if let editorText = response.editorText {
            editorRequest = .init(sessionId: sessionID, revision: Int(Date.now.timeIntervalSince1970 * 1_000), action: .set, text: editorText, fullText: editorText)
        }
        await loadTree()
        return response.editorText
    }

    func setLabel(entryID: String, label: String?) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, entryId: String; let label: String?; let commandId: String }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, entryId: entryID, label: label, commandId: commandID)
        let _: MutationResponse = try await confirmedMutation(method: "session.label", commandId: commandID) {
            try await client.request("session.label", params)
        }
        await loadTree()
    }

    func exportSession(format: String) async throws -> URL {
        guard let sessionID = selectedSessionID else { throw GatewayFailure(code: "no_session", message: "Select a session first.", retryable: false, details: nil) }
        if subscribedSessionID != sessionID, !(await synchronizeSession(sessionID)) {
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
        let commandID = UUID().uuidString
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
        if selectedSessionID == id { selectedSessionID = visibleSessions.first?.id }
        saveCache()
    }

    func loadContext() async {
        guard let sessionID = selectedSessionID else { return }
        if subscribedSessionID != sessionID, !(await synchronizeSession(sessionID)) { return }
        struct Params: Codable { let sessionId: String }
        do {
            let loaded = try await client.requestValue("session.context", Params(sessionId: sessionID), timeout: .seconds(60))
            guard selectedSessionID == sessionID else { return }
            context = loaded
        } catch { surface(error) }
    }

    func loadTree() async {
        guard let sessionID = selectedSessionID else { return }
        if subscribedSessionID != sessionID, !(await synchronizeSession(sessionID)) { return }
        struct Params: Codable { let sessionId: String }
        do {
            let loaded: [SessionTreeNode] = try await client.request("session.tree", Params(sessionId: sessionID))
            guard selectedSessionID == sessionID else { return }
            sessionTree = loaded
        } catch { surface(error) }
    }

    func loadCommands() async {
        guard let sessionID = selectedSessionID else { return }
        await loadCommands(for: sessionID)
    }

    private func loadCommands(for sessionID: String) async {
        if subscribedSessionID != sessionID, !(await synchronizeSession(sessionID)) { return }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let commands: [CommandInfo] }
        do {
            let response: Response = try await client.request("session.commands", Params(sessionId: sessionID))
            guard selectedSessionID == sessionID else { return }
            commands = response.commands
        } catch { surface(error) }
    }

    func loadResources() async {
        guard let sessionID = selectedSessionID else { return }
        if subscribedSessionID != sessionID, !(await synchronizeSession(sessionID)) { return }
        struct Params: Codable { let sessionId: String }
        do {
            let loaded = try await client.requestValue("session.resources", Params(sessionId: sessionID), timeout: .seconds(60))
            guard selectedSessionID == sessionID else { return }
            resources = loaded
        } catch { surface(error) }
    }

    func reloadResources() async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, commandId: String }
        struct Response: Codable { let reloaded: Bool }
        let commandID = UUID().uuidString
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
        if selectedSessionID == id { selectedSessionID = visibleSessions.first?.id }
    }

    func upload(name: String, mimeType: String, data: Data) async throws {
        let id = try await client.upload(name: name, mimeType: mimeType, data: data)
        pendingAttachments.append(PendingAttachment(
            id: id,
            name: name,
            mimeType: mimeType,
            size: data.count,
            previewData: mimeType.hasPrefix("image/") ? data : nil
        ))
    }

    func removeAttachment(_ id: String) { pendingAttachments.removeAll { $0.id == id } }

    func refreshProviders(sessionID: String? = nil, useSelectedProject: Bool = true) async {
        let effectiveSessionID = sessionID ?? (useSelectedProject ? selectedSessionID : nil)
        struct ProviderParams: Codable { let sessionId: String? }
        struct ModelParams: Codable { let sessionId: String?; let cursor: String?; let limit: Int }
        struct ProviderResponse: Decodable { let providers: [ProviderSummary] }
        struct ModelResponse: Decodable { let models: [ModelSummary]; let nextCursor: String? }
        do {
            async let providerRequest: ProviderResponse = client.request("provider.list", ProviderParams(sessionId: effectiveSessionID))
            var catalog: [ModelSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let response: ModelResponse = try await client.request(
                    "model.list",
                    ModelParams(sessionId: effectiveSessionID, cursor: cursor, limit: 500)
                )
                catalog.append(contentsOf: response.models)
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
            providers = try await providerRequest.providers
            models = catalog
            providerRevision &+= 1
        } catch { surface(error) }
    }

    func beginAuth(providerID: String, authType: String, sessionID: String? = nil) async throws {
        struct Params: Codable { let providerId, authType: String; let sessionId: String? }
        struct Response: Decodable { let operationId: String }
        let response: Response = try await client.request("auth.begin", Params(providerId: providerID, authType: authType, sessionId: sessionID), timeout: .seconds(15))
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
        let _: Response? = try? await client.request("auth.cancel", Params(operationId: id))
        if authPrompt?.operationId == id { authPrompt = nil }
        if authEvent?.operationId == id { authEvent = nil }
    }

    func refreshModelCatalog(force: Bool = true) async throws {
        struct Params: Codable { let force: Bool; let sessionId: String?; let commandId: String }
        let commandID = UUID().uuidString
        let params = Params(force: force, sessionId: selectedSessionID, commandId: commandID)
        _ = try await confirmedMutationValue(method: "models.refresh", commandId: commandID) {
            try await client.requestValue("models.refresh", params, timeout: .seconds(75))
        }
        await refreshProviders()
    }

    func logout(providerID: String, sessionID: String? = nil) async throws {
        struct Params: Codable { let providerId, commandId: String; let sessionId: String? }
        struct Response: Codable { let loggedOut: Bool }
        let commandID = UUID().uuidString
        let params = Params(providerId: providerID, commandId: commandID, sessionId: sessionID)
        let _: Response = try await confirmedMutation(method: "auth.logout", commandId: commandID) {
            try await client.request("auth.logout", params, timeout: .seconds(60))
        }
        await refreshProviders(sessionID: sessionID, useSelectedProject: false)
    }

    func refreshSettings(cwd: String? = nil, useSelectedProject: Bool = true) async {
        struct Params: Codable { let cwd: String?; let scope: String }
        do {
            settings = try await client.requestValue(
                "settings.get",
                Params(cwd: cwd ?? (useSelectedProject ? selectedSnapshot?.cwd : nil), scope: useSelectedProject ? "project" : "global")
            )
            settingsRevision &+= 1
        }
        catch { surface(error) }
    }

    func updateSettings(_ patch: JSONValue, scope: String = "global", cwd: String? = nil) async throws {
        struct Params: Codable { let patch: JSONValue; let scope: String; let cwd: String?; let commandId: String }
        let commandID = UUID().uuidString
        let params = Params(patch: patch, scope: scope, cwd: cwd ?? selectedSnapshot?.cwd, commandId: commandID)
        settings = try await confirmedMutationValue(method: "settings.update", commandId: commandID) {
            try await client.requestValue("settings.update", params, timeout: .seconds(60))
        }
        await refreshSettings(cwd: cwd)
    }

    func inspectTrust(cwd: String) async throws -> JSONValue {
        struct Params: Codable { let cwd: String }
        return try await client.requestValue("trust.inspect", Params(cwd: cwd))
    }

    func setTrust(cwd: String, decision: Bool?) async throws -> JSONValue {
        struct Params: Codable { let cwd: String; let decision: Bool?; let commandId: String }
        let commandID = UUID().uuidString
        let params = Params(cwd: cwd, decision: decision, commandId: commandID)
        return try await confirmedMutationValue(method: "trust.set", commandId: commandID) {
            try await client.requestValue("trust.set", params)
        }
    }

    func loadPackages(cwd: String? = nil) async {
        struct Params: Codable { let cwd: String? }
        do {
            packageState = try await client.request("packages.list", Params(cwd: cwd), timeout: .seconds(120))
            packageRevision &+= 1
        }
        catch { surface(error) }
    }

    func checkPackageUpdates(cwd: String? = nil) async {
        struct Params: Codable { let cwd: String? }
        struct Response: Decodable { let updates: [PackageUpdate] }
        do {
            let response: Response = try await client.request("packages.checkUpdates", Params(cwd: cwd), timeout: .seconds(180))
            packageUpdates = response.updates
        } catch { surface(error) }
    }

    func mutatePackage(action: String, source: String?, local: Bool, cwd: String?) async throws {
        struct Params: Codable { let source: String?; let local: Bool; let cwd: String?; let commandId: String }
        let method = "packages.\(action)"
        let commandID = UUID().uuidString
        let params = Params(source: source, local: local, cwd: cwd, commandId: commandID)
        _ = try await confirmedMutationValue(method: method, commandId: commandID) {
            try await client.requestValue(method, params, timeout: .seconds(300))
        }
        await loadPackages(cwd: cwd)
    }

    func loadCustomModels() async {
        do {
            customModels = try await client.requestValue("models.custom.get", EmptyParams())
            customModelRevision &+= 1
        }
        catch { surface(error) }
    }

    func replaceCustomModels(_ document: JSONValue) async throws {
        let client = self.client
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
        }).replace(document)
    }

    func restartGateway() async throws {
        struct Params: Codable { let commandId: String }
        let commandID = UUID().uuidString
        _ = try await client.requestValue("gateway.restart", Params(commandId: commandID))
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
        let commandID = UUID().uuidString
        let params = Params(parent: parent, name: name, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "filesystem.mkdir", commandId: commandID) {
            try await client.request("filesystem.mkdir", params)
        }
        try await loadWorkspace(path: parent)
        defaultWorkspace = response.path
    }

    func answerInteraction(_ interaction: ExtensionInteraction, value: JSONValue?, cancelled: Bool) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, interactionId: String; let value: JSONValue?; let cancelled: Bool; let commandId: String }
        struct Response: Codable { let answered: Bool }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, interactionId: interaction.id, value: value, cancelled: cancelled, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "extension.respond", commandId: commandID) {
            try await client.request("extension.respond", params)
        }
    }

    func listTerminals() async throws -> [TerminalSummary] {
        guard let sessionID = selectedSessionID else { return [] }
        if subscribedSessionID != sessionID, !(await synchronizeSession(sessionID)) {
            throw GatewayFailure(code: "sync_failed", message: "Open the session before listing terminals.", retryable: true, details: nil)
        }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let terminals: [TerminalSummary] }
        let response: Response = try await client.request("terminal.list", Params(sessionId: sessionID))
        let attached = terminals.filter { attachedTerminalIDs.contains($0.id) }
        terminals = response.terminals + attached.filter { terminal in
            !response.terminals.contains { $0.id == terminal.id }
        }
        return response.terminals
    }

    func openTerminal(columns: Int, rows: Int) async throws -> TerminalSummary {
        guard let sessionID = selectedSessionID else { throw GatewayFailure(code: "no_session", message: "Select a session first.", retryable: false, details: nil) }
        struct Params: Codable { let sessionId: String; let columns, rows: Int; let commandId: String }
        struct Replay: Codable { let terminal: TerminalSummary; let chunks: [TerminalChunk]; let reset: Bool }
        struct Response: Codable { let terminal: TerminalSummary; let replay: Replay }
        let commandID = UUID().uuidString
        let params = Params(sessionId: sessionID, columns: columns, rows: rows, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "terminal.open", commandId: commandID) {
            try await client.request("terminal.open", params)
        }
        terminalChunks[response.terminal.id] = response.replay.chunks
        upsertTerminal(response.terminal)
        attachedTerminalIDs.insert(response.terminal.id)
        return response.terminal
    }

    func attachTerminal(_ id: String, after: Int) async throws -> TerminalSummary {
        struct Params: Codable { let terminalId: String; let afterSequence: Int }
        struct Response: Decodable { let terminal: TerminalSummary; let chunks: [TerminalChunk]; let reset: Bool }
        let response: Response = try await client.request("terminal.attach", Params(terminalId: id, afterSequence: after))
        if response.reset { terminalChunks[id] = response.chunks }
        else {
            let latest = terminalChunks[id]?.last?.sequence ?? after
            terminalChunks[id, default: []].append(contentsOf: response.chunks.filter { $0.sequence > latest })
        }
        upsertTerminal(response.terminal)
        attachedTerminalIDs.insert(id)
        return response.terminal
    }

    func detachTerminal(_ id: String) async {
        struct Params: Codable { let terminalId: String }
        struct Response: Decodable { let detached: Bool }
        let _: Response? = try? await client.request("terminal.detach", Params(terminalId: id))
        attachedTerminalIDs.remove(id)
    }

    func writeTerminal(_ id: String, data: String) async throws {
        struct Params: Codable { let terminalId, writeId, data, commandId: String }
        struct Response: Codable { let written: Bool }
        let identity = UUID().uuidString
        let params = Params(terminalId: id, writeId: identity, data: data, commandId: identity)
        let _: Response = try await confirmedMutation(method: "terminal.write", commandId: identity) {
            try await client.request("terminal.write", params)
        }
    }

    func resizeTerminal(_ id: String, columns: Int, rows: Int) async throws {
        struct Params: Codable { let terminalId: String; let columns, rows: Int; let commandId: String }
        struct Response: Codable { let resized: Bool }
        let commandID = UUID().uuidString
        let params = Params(terminalId: id, columns: columns, rows: rows, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "terminal.resize", commandId: commandID) {
            try await client.request("terminal.resize", params)
        }
    }

    func terminateTerminal(_ id: String) async throws {
        struct Params: Codable { let terminalId, commandId: String }
        struct Response: Codable { let terminated: Bool }
        let commandID = UUID().uuidString
        let params = Params(terminalId: id, commandId: commandID)
        let _: Response = try await confirmedMutation(method: "terminal.terminate", commandId: commandID) {
            try await client.request("terminal.terminate", params)
        }
    }

    func handle(_ event: GatewayEvent) async {
        if event.topic.hasPrefix("session."), event.topic != "session.listChanged", event.topic != "session.summary" {
            switch sessionEventSynchronizer.admit(event) {
            case .deliver(let event):
                await handleDeliveredEvent(event)
            case .buffered:
                break
            case .overflow(let sessionID):
                _ = await synchronizeSession(sessionID)
            }
            return
        }
        await handleDeliveredEvent(event)
    }

    private func handleDeliveredEvent(_ event: GatewayEvent) async {
        switch event.topic {
        case "transport.disconnected", "system.stopping":
            subscribedSessionID = nil
            liveSessionSummaryUpdates.removeAll()
            sessions = sessions.map(\.safeCachedProjection)
            sessionEventSynchronizer.reset()
            pendingAuthoritativeResyncSessionIDs.removeAll()
            pendingBranchReplacementSessionIDs.removeAll()
            connectionState = .reconnecting
            reconnectTask?.cancel()
            reconnectTask = nil
            scheduleReconnect()
        case "transport.resyncRequired":
            if let sessionID = event.sessionId ?? selectedSessionID {
                pendingAuthoritativeResyncSessionIDs.insert(sessionID)
                _ = await synchronizeSession(sessionID)
            }
        case "session.summary":
            if let update = try? event.payload.decode(SessionSummaryUpdate.self) {
                apply(update)
            }
        case "session.listChanged":
            scheduleSessionListRefresh()
        case "session.snapshot":
            if let snapshot = try? event.payload.decode(SessionSnapshot.self),
               let current = snapshots[snapshot.sessionId] {
                if snapshot.runtimeGeneration == current.runtimeGeneration,
                   snapshot.eventSequence > current.eventSequence + 1 {
                    pendingAuthoritativeResyncSessionIDs.insert(snapshot.sessionId)
                    _ = await synchronizeSession(snapshot.sessionId)
                } else {
                    apply(snapshot)
                    if snapshot.sessionId == selectedSessionID { subscribedSessionID = snapshot.sessionId }
                }
            } else if let snapshot = try? event.payload.decode(SessionSnapshot.self) {
                apply(snapshot)
            }
        case "session.progress":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  let message = envelope.data.objectValue?["message"], message != .null,
                  let item = try? message.decode(TranscriptItem.self),
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.streaming = item
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.toolProgress":
            guard let (sessionID, envelope) = admitSessionEvent(event),
                  let tool = try? envelope.data.decode(ToolExecutionState.self),
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
                  let interactions = try? envelope.data.decode([ExtensionInteraction].self),
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
                  let object = envelope.data.objectValue,
                  let key = object["key"]?.stringValue,
                  var snapshot = snapshots[sessionID] else { break }
            snapshot.extensionUI.widgets.removeAll { $0.key == key }
            if object["lines"] != .null, let widget = try? envelope.data.decode(ExtensionWidget.self) {
                snapshot.extensionUI.widgets.append(widget)
            }
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
            editorRequest = .init(sessionId: sessionID, revision: editorRevision, action: action, text: text, fullText: fullText)
            advance(&snapshot, envelope)
            snapshots[sessionID] = snapshot
        case "session.notification":
            guard let (sessionID, envelope) = admitSessionEvent(event) else { break }
            if let message = envelope.data.objectValue?["message"]?.stringValue { notifications.append(message) }
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
                pendingBranchReplacementSessionIDs.insert(sessionID)
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
        case "auth.prompt":
            parseAuthPrompt(event.payload)
        case "auth.event":
            parseAuthEvent(event.payload)
        case "auth.completed":
            authPrompt = nil
            authEvent = nil
            await refreshProviders()
            if event.payload.objectValue?["success"]?.boolValue == false {
                lastError = event.payload.objectValue?["error"]?.stringValue
            }
        case "settings.changed":
            settingsRevision &+= 1
        case "trust.changed":
            trustRevision &+= 1
            settingsRevision &+= 1
        case "providers.changed":
            providerRevision &+= 1
        case "packages.changed":
            packageRevision &+= 1
        case "models.customChanged":
            customModelRevision &+= 1
        case "packages.progress", "packages.completed":
            notifications.append(event.topic == "packages.completed" ? "Package operation completed" : "Updating agent package…")
        case "terminal.output":
            if let object = event.payload.objectValue,
               let terminalID = object["terminalId"]?.stringValue,
               let sequence = object["sequence"]?.intValue,
               let data = object["data"]?.stringValue {
                let latest = terminalChunks[terminalID]?.last?.sequence ?? 0
                guard sequence > latest else { break }
                guard sequence == latest + 1 else {
                    reconcileTerminal(terminalID)
                    break
                }
                terminalChunks[terminalID, default: []].append(TerminalChunk(sequence: sequence, data: data))
                if terminalChunks[terminalID, default: []].count > 2_048 {
                    terminalChunks[terminalID]?.removeFirst(terminalChunks[terminalID]!.count - 2_048)
                }
                updateTerminalSequence(terminalID, sequence: sequence)
            }
        case "terminal.exit":
            if let id = event.payload.objectValue?["terminalId"]?.stringValue {
                terminalExited.insert(id)
                if let index = terminals.firstIndex(where: { $0.id == id }) {
                    let current = terminals[index]
                    terminals[index] = TerminalSummary(
                        id: current.id,
                        sessionId: current.sessionId,
                        cwd: current.cwd,
                        createdAt: current.createdAt,
                        exitedAt: ISO8601DateFormatter().string(from: .now),
                        exitCode: event.payload.objectValue?["exitCode"]?.intValue,
                        sequence: max(current.sequence, event.payload.objectValue?["sequence"]?.intValue ?? current.sequence)
                    )
                }
            }
        default:
            if event.topic.hasPrefix("session."),
               let (sessionID, envelope) = admitSessionEvent(event) {
                // Unknown sequenced session events still advance the cursor.
                // This preserves forward-compatible ordering for the next event.
                advanceSessionCursor(sessionID, envelope)
            }
        }
    }

    private func admitSessionEvent(_ event: GatewayEvent) -> (String, SessionEventEnvelope)? {
        guard let sessionID = event.sessionId,
              let envelope = try? event.payload.decode(SessionEventEnvelope.self),
              let snapshot = snapshots[sessionID] else { return nil }
        guard envelope.runtimeGeneration == snapshot.runtimeGeneration else {
            if !sessionEventSynchronizer.isSynchronizing(sessionID: sessionID) {
                Task { await synchronizeSession(sessionID) }
            }
            return nil
        }
        guard envelope.eventSequence > snapshot.eventSequence else { return nil }
        guard envelope.eventSequence == snapshot.eventSequence + 1 else {
            if !sessionEventSynchronizer.isSynchronizing(sessionID: sessionID) {
                Task { await synchronizeSession(sessionID) }
            }
            return nil
        }
        return (sessionID, envelope)
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
        presentationGeneration: Int? = nil
    ) async -> Bool {
        if sessionEventSynchronizer.isSynchronizing(sessionID: sessionID) {
            let token = sessionEventSynchronizer.token(sessionID: sessionID)
            let deadline = ContinuousClock.now + .seconds(65)
            while sessionEventSynchronizer.token(sessionID: sessionID) == token, ContinuousClock.now < deadline {
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard sessionEventSynchronizer.token(sessionID: sessionID) != token else { return false }
            if replacingVisibleTranscript {
                return await synchronizeSession(
                    sessionID,
                    replacingVisibleTranscript: true,
                    presentationGeneration: presentationGeneration
                )
            }
            if pendingAuthoritativeResyncSessionIDs.remove(sessionID) != nil {
                return await synchronizeSession(sessionID)
            }
            return snapshots[sessionID] != nil
        }
        let token = sessionEventSynchronizer.begin(sessionID: sessionID)
        do {
            struct Params: Codable { let sessionId: String }
            let response: SessionOpenResponse = try await client.request("session.open", Params(sessionId: sessionID), timeout: .seconds(60))
            if let presentationGeneration,
               presentationGeneration != self.presentationOpenGeneration || selectedSessionID != sessionID {
                sessionEventSynchronizer.cancel(sessionID: sessionID, token: token)
                // The same-session subscription may already belong to a newer
                // mount. Only close when selection has moved elsewhere; request
                // ordering then guarantees a later open owns the final state.
                if selectedSessionID != sessionID,
                   mountedPresentationGenerationBySession[sessionID] == nil {
                    await closeSubscription(sessionID)
                }
                return false
            }
            subscribedSessionID = sessionID
            if replacingVisibleTranscript || pendingBranchReplacementSessionIDs.remove(sessionID) != nil {
                snapshots[sessionID] = Self.installingSnapshot(
                    current: snapshots[sessionID],
                    authoritative: response.session,
                    mode: .freshPresentation
                )
            } else {
                apply(response.session)
            }
            try await acknowledgeSessionSync(sessionID: sessionID, syncToken: response.syncToken)
            let installed = snapshots[sessionID] ?? response.session
            let cursor = SessionEventSynchronizer.Cursor(
                runtimeGeneration: installed.runtimeGeneration,
                eventSequence: installed.eventSequence
            )
            guard let replay = sessionEventSynchronizer.complete(sessionID: sessionID, token: token, baseline: cursor) else {
                return await synchronizeSession(
                    sessionID,
                    replacingVisibleTranscript: replacingVisibleTranscript,
                    presentationGeneration: presentationGeneration
                )
            }
            for event in replay { await handleDeliveredEvent(event) }
            if pendingAuthoritativeResyncSessionIDs.remove(sessionID) != nil {
                return await synchronizeSession(
                    sessionID,
                    replacingVisibleTranscript: replacingVisibleTranscript,
                    presentationGeneration: presentationGeneration
                )
            }
            notifications = Self.removingSessionCatchUpNotice(from: notifications)
            return true
        } catch {
            // The failed baseline is not authoritative. Discard quarantined
            // events and let the next open replace it instead of applying them
            // against a stale cached snapshot or surfacing a transient sync race.
            sessionEventSynchronizer.cancel(sessionID: sessionID, token: token)
            await closeSubscription(sessionID)
            if let failure = error as? GatewayFailure,
               failure.retryable || failure.code == "response_too_large" {
                // A failed attempt is not an invalidation that arrived during a
                // successful baseline. Leaving a pending marker here makes a
                // manual Retry immediately perform a redundant second open.
                if !notifications.contains(Self.sessionCatchUpNotice) {
                    notifications.append(Self.sessionCatchUpNotice)
                }
            } else {
                surface(error)
            }
            return false
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

    private func apply(_ snapshot: SessionSnapshot) {
        if let current = snapshots[snapshot.sessionId],
           current.runtimeGeneration == snapshot.runtimeGeneration,
           snapshot.eventSequence < current.eventSequence {
            return
        }
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
        if let index = sessions.firstIndex(where: { $0.id == snapshot.sessionId }) {
            let current = sessions[index]
            sessions[index] = SessionSummary(
                id: current.id,
                name: installed.name,
                cwd: current.cwd,
                parentSessionId: current.parentSessionId,
                createdAt: current.createdAt,
                updatedAt: current.updatedAt,
                messageCount: current.messageCount,
                firstMessage: current.firstMessage,
                phase: installed.phase,
                summaryRevision: current.summaryRevision
            )
        }
    }

    static func installingSnapshot(
        current: SessionSnapshot?,
        authoritative: SessionSnapshot,
        mode: SessionSnapshotInstallMode
    ) -> SessionSnapshot {
        switch mode {
        case .freshPresentation:
            authoritative
        case .reconnect:
            current.map { mergingVisibleTranscript(current: $0, authoritative: authoritative) } ?? authoritative
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
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.refreshSessions()
        }
    }

    private func clearLiveConnectionState() {
        liveSessionSummaryUpdates.removeAll()
        attachedTerminalIDs.removeAll()
        reconcilingTerminalIDs.removeAll()
        terminals.removeAll()
        terminalChunks.removeAll()
        terminalExited.removeAll()
        sessionStructureRevisions.removeAll()
        sessionContextRevisions.removeAll()
        sessionResourceRevisions.removeAll()
    }

    private func upsertTerminal(_ terminal: TerminalSummary) {
        if let index = terminals.firstIndex(where: { $0.id == terminal.id }) { terminals[index] = terminal }
        else { terminals.append(terminal) }
        if terminal.exitedAt == nil { terminalExited.remove(terminal.id) }
        else { terminalExited.insert(terminal.id) }
    }

    private func updateTerminalSequence(_ terminalID: String, sequence: Int) {
        guard let index = terminals.firstIndex(where: { $0.id == terminalID }) else { return }
        let terminal = terminals[index]
        terminals[index] = TerminalSummary(
            id: terminal.id,
            sessionId: terminal.sessionId,
            cwd: terminal.cwd,
            createdAt: terminal.createdAt,
            exitedAt: terminal.exitedAt,
            exitCode: terminal.exitCode,
            sequence: max(terminal.sequence, sequence)
        )
    }

    private func reconcileTerminal(_ terminalID: String) {
        guard attachedTerminalIDs.contains(terminalID), reconcilingTerminalIDs.insert(terminalID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.reconcilingTerminalIDs.remove(terminalID) }
            let after = self.terminalChunks[terminalID]?.last?.sequence ?? 0
            _ = try? await self.attachTerminal(terminalID, after: after)
        }
    }

    private func reattachTerminals() async {
        for terminalID in attachedTerminalIDs {
            let after = terminalChunks[terminalID]?.last?.sequence ?? 0
            _ = try? await attachTerminal(terminalID, after: after)
        }
    }

    private func reconcileSelection() {
        defaultWorkspace = UserDefaults.standard.string(forKey: "defaultWorkspace.v1")
        loadHidden()
        selectedSessionID = SessionSelectionPolicy.reconcile(
            selected: selectedSessionID,
            visibleIDs: Set(visibleSessions.map(\.id)),
            locallyCreatedUnindexedIDs: locallyCreatedUnindexedSessionIDs,
            firstVisibleID: visibleSessions.first?.id
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
        do { return try await send() }
        catch let original as GatewayFailure where Self.isUncertainTransportFailure(original) {
            let deadline = ContinuousClock.now + .seconds(90)
            var lastFailure: GatewayFailure = original
            while ContinuousClock.now < deadline {
                if Task.isCancelled { throw CancellationError() }
                guard await waitForConnected(until: deadline) else { break }
                do {
                    let status: CommandStatusResponse = try await client.request(
                        "command.status",
                        CommandStatusParams(method: method, commandId: commandId),
                        timeout: .seconds(10)
                    )
                    switch status.status {
                    case "completed":
                        guard let result = status.result else {
                            throw GatewayFailure(code: "invalid_response", message: "The completed command did not include a result.", retryable: false, details: nil)
                        }
                        return result
                    case "missing":
                        do { return try await send() }
                        catch let retry as GatewayFailure where Self.isUncertainTransportFailure(retry) {
                            lastFailure = retry
                        }
                    case "pending":
                        break
                    default:
                        throw GatewayFailure(code: "invalid_response", message: "Tron returned an unknown command status.", retryable: false, details: nil)
                    }
                } catch let failure as GatewayFailure where Self.isUncertainTransportFailure(failure) {
                    lastFailure = failure
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            throw GatewayFailure(
                code: "outcome_unknown",
                message: "Tron may have accepted this command. The session was refreshed without replaying it; verify the authoritative transcript before trying again.",
                retryable: false,
                details: .object([
                    "commandId": .string(commandId),
                    "method": .string(method),
                    "lastFailure": .string(lastFailure.message),
                ])
            )
        }
    }

    private func waitForConnected(until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if connectionState == .connected { return true }
            if connectionState == .unauthorized || connectionState == .unpaired { return false }
            if reconnectTask == nil { scheduleReconnect(immediate: true) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func isUncertainTransportFailure(_ failure: GatewayFailure) -> Bool {
        failure.retryable || ["timeout", "disconnected", "closed", "replaced"].contains(failure.code)
    }

    static let sessionCatchUpNotice = "Live session view is catching up; the run continues on your Mac."

    static func removingSessionCatchUpNotice(from notifications: [String]) -> [String] {
        notifications.filter { $0 != sessionCatchUpNotice }
    }

    static func shouldSurface(_ error: Error) -> Bool {
        if error is CancellationError { return false }
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

    private func loadCache(profileID: String) async {
        let value = await cache.load(profileID: profileID)
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
