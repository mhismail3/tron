import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    enum ConnectionState: Equatable {
        case unpaired, connecting, connected, reconnecting, unauthorized, offline(String)
    }

    struct PendingAttachment: Identifiable, Hashable {
        let id: String
        let name: String
        let mimeType: String
        let size: Int
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
    var selectedSessionID: String?
    var snapshots: [String: SessionSnapshot] = [:]
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
    private var refreshTask: Task<Void, Never>?
    private var subscribedSessionID: String?
    private var resyncingSessionIDs: Set<String> = []
    private var hiddenSessionIDs: Set<String> = []
    private var locallyCreatedUnindexedSessionIDs: Set<String> = []

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
        guard connectionState != .connected,
              connectionState != .connecting,
              connectionState != .reconnecting else { return }
        scheduleReconnect(immediate: true)
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
        selectedSessionID = nil
        subscribedSessionID = nil
        await loadCache(profileID: profile.id)
        await connect(profile: profile, token: token)
    }

    func forgetCurrentGateway() {
        if let profile = profiles.selected { profiles.remove(profile) }
        Task { await client.close() }
        gatewayInfo = nil
        sessions = []
        snapshots = [:]
        selectedSessionID = nil
        subscribedSessionID = nil
        setupComplete = false
        connectionState = .unpaired
        hasResolvedLaunchState = true
    }

    private func connect(profile: GatewayProfile, token: String) async {
        connectionState = .connecting
        do {
            gatewayInfo = try await client.connect(profile: profile, token: token)
            subscribedSessionID = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            await refreshAll()
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
                    await self.refreshAll()
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

    func refreshAll() async {
        await refreshSessions()
        async let providerLoad: Void = refreshProviders()
        async let settingLoad: Void = refreshSettings()
        async let deviceLoad: Void = refreshDevices()
        _ = await (providerLoad, settingLoad, deviceLoad)
        if let selectedSessionID { try? await openSession(selectedSessionID) }
    }

    func refreshSessions() async {
        struct Params: Encodable { let cursor: String?; let limit: Int }
        struct Response: Decodable { let sessions: [SessionSummary]; let nextCursor: String? }
        do {
            var all: [SessionSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let response: Response = try await client.request(
                    "session.list",
                    Params(cursor: cursor, limit: 200)
                )
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
            sessions = all
            locallyCreatedUnindexedSessionIDs.subtract(all.map(\.id))
            reconcileSelection()
            saveCache()
        } catch { surface(error) }
    }

    func refreshDevices() async {
        struct Response: Decodable { let devices: [PairedDevice] }
        do {
            let response: Response = try await client.request("device.list", EmptyParams())
            pairedDevices = response.devices
        } catch { surface(error) }
    }

    func revokeDevice(_ id: String) async throws {
        struct Params: Encodable { let deviceId: String; let commandId: String }
        struct Response: Decodable { let revoked: Bool }
        let response: Response = try await client.request(
            "device.revoke",
            Params(deviceId: id, commandId: UUID().uuidString)
        )
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
        struct Params: Encodable { let port: Int; let commandId: String }
        struct Response: Decodable { let imported: Int; let skipped: Int }
        let response: Response = try await client.request(
            "legacy.import",
            Params(port: port, commandId: UUID().uuidString),
            timeout: .seconds(600)
        )
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
        struct Response: Decodable { let session: SessionSnapshot }
        await closeCurrentSubscription()
        let commandID = UUID().uuidString
        let params = Params(uploadId: uploadID, cwd: cwd, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.import", commandId: commandID) {
            try await client.request("session.import", params, timeout: .seconds(120))
        }
        selectedSessionID = response.session.sessionId
        subscribedSessionID = response.session.sessionId
        apply(response.session)
        await refreshSessions()
    }

    func createSession(cwd: String) async throws {
        struct Params: Codable { let cwd: String; let commandId: String }
        struct Response: Decodable { let session: SessionSnapshot }
        await closeCurrentSubscription()
        let commandID = UUID().uuidString
        let params = Params(cwd: cwd, commandId: commandID)
        let response: Response = try await confirmedMutation(method: "session.create", commandId: commandID) {
            try await client.request("session.create", params, timeout: .seconds(60))
        }
        snapshots[response.session.sessionId] = response.session
        locallyCreatedUnindexedSessionIDs.insert(response.session.sessionId)
        selectedSessionID = response.session.sessionId
        subscribedSessionID = response.session.sessionId
        defaultWorkspace = cwd
        UserDefaults.standard.set(cwd, forKey: "defaultWorkspace.v1")
        await refreshSessions()
    }

    func openSession(_ id: String) async throws {
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let session: SessionSnapshot }
        if subscribedSessionID != id { await closeCurrentSubscription() }
        selectedSessionID = id
        let response: Response = try await client.request("session.open", Params(sessionId: id), timeout: .seconds(60))
        subscribedSessionID = response.session.sessionId
        apply(response.session)
        async let providerRefresh: Void = refreshProviders()
        async let commandRefresh: Void = loadCommands()
        _ = await (providerRefresh, commandRefresh)
    }

    func loadEarlierTranscript() async {
        guard !loadingEarlierTranscript,
              let sessionID = selectedSessionID,
              let current = snapshots[sessionID],
              let before = current.transcriptStart,
              before > 0 else { return }
        struct Params: Codable { let sessionId: String; let before: Int }
        struct Response: Decodable { let items: [TranscriptItem]; let start: Int; let total: Int }
        loadingEarlierTranscript = true
        defer { loadingEarlierTranscript = false }
        do {
            let response: Response = try await client.request(
                "session.transcript",
                Params(sessionId: sessionID, before: before),
                timeout: .seconds(60)
            )
            guard var snapshot = snapshots[sessionID], snapshot.runtimeGeneration == current.runtimeGeneration else { return }
            let existingIDs = Set(snapshot.transcript.map(\.id))
            snapshot.transcript = response.items.filter { !existingIDs.contains($0.id) } + snapshot.transcript
            snapshot.transcriptStart = response.start
            snapshot.transcriptTotal = response.total
            snapshots[sessionID] = snapshot
        } catch { surface(error) }
    }

    private func closeCurrentSubscription() async {
        guard let sessionID = subscribedSessionID else { return }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let closed: Bool }
        let _: Response? = try? await client.request("session.close", Params(sessionId: sessionID))
        subscribedSessionID = nil
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
        struct Response: Decodable { let operationId: String }
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
        struct Response: Decodable { let aborted: Bool }
        do { let _: Response = try await client.request("session.abort", Params(sessionId: sessionID, kind: kind, commandId: UUID().uuidString), timeout: .seconds(30)) }
        catch { surface(error) }
    }

    func clearQueue() async throws -> SessionSnapshot.QueuedMessages {
        guard let sessionID = selectedSessionID else { return .init(steering: [], followUp: []) }
        struct Params: Codable { let sessionId, commandId: String }
        let cleared: SessionSnapshot.QueuedMessages = try await client.request("session.clearQueue", Params(sessionId: sessionID, commandId: UUID().uuidString))
        if var snapshot = snapshots[sessionID] {
            snapshot.queued = .init(steering: [], followUp: [])
            snapshots[sessionID] = snapshot
        }
        return cleared
    }

    func executeBash(_ command: String, excludeFromContext: Bool = false) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, command: String; let excludeFromContext: Bool; let commandId: String }
        _ = try await client.requestValue(
            "session.bash",
            Params(sessionId: sessionID, command: command, excludeFromContext: excludeFromContext, commandId: UUID().uuidString),
            timeout: .seconds(300)
        )
    }

    func setModel(_ model: ModelRef) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, provider, modelId, commandId: String }
        let _: MutationResponse = try await client.request("session.setModel", Params(sessionId: sessionID, provider: model.provider, modelId: model.id, commandId: UUID().uuidString))
    }

    func setThinking(_ level: String) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, level, commandId: String }
        let _: MutationResponse = try await client.request("session.setThinking", Params(sessionId: sessionID, level: level, commandId: UUID().uuidString))
    }

    func rename(_ name: String) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, name, commandId: String }
        let _: MutationResponse = try await client.request("session.rename", Params(sessionId: sessionID, name: name, commandId: UUID().uuidString))
    }

    func compact(instructions: String? = nil) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String; let instructions: String?; let commandId: String }
        struct Response: Decodable { let compacted: Bool }
        let _: Response = try await client.request("session.compact", Params(sessionId: sessionID, instructions: instructions, commandId: UUID().uuidString), timeout: .seconds(300))
    }

    func setTools(_ tools: [String]) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String; let tools: [String]; let commandId: String }
        let _: MutationResponse = try await client.request("session.setTools", Params(sessionId: sessionID, tools: tools, commandId: UUID().uuidString))
    }

    @discardableResult
    func fork(entryID: String, position: String = "before") async throws -> String? {
        guard let sessionID = selectedSessionID else { return nil }
        struct Params: Codable { let sessionId, entryId, position, commandId: String }
        struct Response: Decodable { let sessionId: String; let selectedText: String? }
        let response: Response = try await client.request("session.fork", Params(sessionId: sessionID, entryId: entryID, position: position, commandId: UUID().uuidString), timeout: .seconds(120))
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
        struct Response: Decodable { let editorText: String? }
        let response: Response = try await client.request(
            "session.navigate",
            Params(sessionId: sessionID, entryId: entryID, summarize: summarize, instructions: instructions, replaceInstructions: replaceInstructions, label: label, commandId: UUID().uuidString),
            timeout: .seconds(300)
        )
        if let editorText = response.editorText {
            editorRequest = .init(sessionId: sessionID, revision: Int(Date.now.timeIntervalSince1970 * 1_000), action: .set, text: editorText, fullText: editorText)
        }
        await loadTree()
        return response.editorText
    }

    func setLabel(entryID: String, label: String?) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, entryId: String; let label: String?; let commandId: String }
        let _: MutationResponse = try await client.request("session.label", Params(sessionId: sessionID, entryId: entryID, label: label, commandId: UUID().uuidString))
        await loadTree()
    }

    func exportSession(format: String) async throws -> URL {
        guard let sessionID = selectedSessionID else { throw GatewayFailure(code: "no_session", message: "Select a session first.", retryable: false, details: nil) }
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
        struct Response: Decodable { let deleted: Bool }
        if subscribedSessionID == id { await closeCurrentSubscription() }
        let _: Response = try await client.request("session.delete", Params(sessionId: id, commandId: UUID().uuidString), timeout: .seconds(60))
        snapshots.removeValue(forKey: id)
        locallyCreatedUnindexedSessionIDs.remove(id)
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = visibleSessions.first?.id }
        saveCache()
    }

    func loadContext() async {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String }
        do { context = try await client.requestValue("session.context", Params(sessionId: sessionID), timeout: .seconds(60)) }
        catch { surface(error) }
    }

    func loadTree() async {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String }
        do { sessionTree = try await client.request("session.tree", Params(sessionId: sessionID)) }
        catch { surface(error) }
    }

    func loadCommands() async {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let commands: [CommandInfo] }
        do {
            let response: Response = try await client.request("session.commands", Params(sessionId: sessionID))
            commands = response.commands
        } catch { surface(error) }
    }

    func loadResources() async {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId: String }
        do { resources = try await client.requestValue("session.resources", Params(sessionId: sessionID), timeout: .seconds(60)) }
        catch { surface(error) }
    }

    func reloadResources() async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, commandId: String }
        struct Response: Decodable { let reloaded: Bool }
        let _: Response = try await client.request("session.reloadResources", Params(sessionId: sessionID, commandId: UUID().uuidString), timeout: .seconds(120))
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
        pendingAttachments.append(PendingAttachment(id: id, name: name, mimeType: mimeType, size: data.count))
    }

    func removeAttachment(_ id: String) { pendingAttachments.removeAll { $0.id == id } }

    func refreshProviders() async {
        struct ProviderParams: Codable { let sessionId: String? }
        struct ModelParams: Codable { let sessionId: String?; let cursor: String?; let limit: Int }
        struct ProviderResponse: Decodable { let providers: [ProviderSummary] }
        struct ModelResponse: Decodable { let models: [ModelSummary]; let nextCursor: String? }
        do {
            async let providerRequest: ProviderResponse = client.request("provider.list", ProviderParams(sessionId: selectedSessionID))
            var catalog: [ModelSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                let response: ModelResponse = try await client.request(
                    "model.list",
                    ModelParams(sessionId: selectedSessionID, cursor: cursor, limit: 500)
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
        } catch { surface(error) }
    }

    func beginAuth(providerID: String, authType: String) async throws {
        struct Params: Codable { let providerId, authType: String; let sessionId: String? }
        struct Response: Decodable { let operationId: String }
        let response: Response = try await client.request("auth.begin", Params(providerId: providerID, authType: authType, sessionId: selectedSessionID), timeout: .seconds(15))
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
        authPrompt = nil
    }

    func cancelAuth(operationID: String? = nil) async {
        guard let id = operationID ?? authPrompt?.operationId ?? authEvent?.operationId else { return }
        struct Params: Codable { let operationId: String }
        struct Response: Decodable { let cancelled: Bool }
        let _: Response? = try? await client.request("auth.cancel", Params(operationId: id))
        authPrompt = nil
        authEvent = nil
    }

    func refreshModelCatalog(force: Bool = true) async throws {
        struct Params: Codable { let force: Bool; let sessionId: String?; let commandId: String }
        _ = try await client.requestValue("models.refresh", Params(force: force, sessionId: selectedSessionID, commandId: UUID().uuidString), timeout: .seconds(75))
        await refreshProviders()
    }

    func logout(providerID: String) async throws {
        struct Params: Codable { let providerId, commandId: String; let sessionId: String? }
        struct Response: Decodable { let loggedOut: Bool }
        let _: Response = try await client.request("auth.logout", Params(providerId: providerID, commandId: UUID().uuidString, sessionId: selectedSessionID), timeout: .seconds(60))
        await refreshProviders()
    }

    func refreshSettings(cwd: String? = nil) async {
        struct Params: Codable { let cwd: String? }
        do { settings = try await client.requestValue("settings.get", Params(cwd: cwd ?? selectedSnapshot?.cwd)) }
        catch { surface(error) }
    }

    func updateSettings(_ patch: JSONValue, scope: String = "global", cwd: String? = nil) async throws {
        struct Params: Codable { let patch: JSONValue; let scope: String; let cwd: String?; let commandId: String }
        settings = try await client.requestValue(
            "settings.update",
            Params(patch: patch, scope: scope, cwd: cwd ?? selectedSnapshot?.cwd, commandId: UUID().uuidString),
            timeout: .seconds(60)
        )
        await refreshSettings(cwd: cwd)
    }

    func inspectTrust(cwd: String) async throws -> JSONValue {
        struct Params: Codable { let cwd: String }
        return try await client.requestValue("trust.inspect", Params(cwd: cwd))
    }

    func setTrust(cwd: String, decision: Bool?) async throws -> JSONValue {
        struct Params: Codable { let cwd: String; let decision: Bool?; let commandId: String }
        return try await client.requestValue("trust.set", Params(cwd: cwd, decision: decision, commandId: UUID().uuidString))
    }

    func loadPackages(cwd: String? = nil) async {
        struct Params: Codable { let cwd: String? }
        do { packageState = try await client.request("packages.list", Params(cwd: cwd), timeout: .seconds(120)) }
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
        _ = try await client.requestValue("packages.\(action)", Params(source: source, local: local, cwd: cwd, commandId: UUID().uuidString), timeout: .seconds(300))
        await loadPackages(cwd: cwd)
    }

    func loadCustomModels() async {
        do { customModels = try await client.requestValue("models.custom.get", EmptyParams()) }
        catch { surface(error) }
    }

    func replaceCustomModels(_ document: JSONValue) async throws {
        let client = self.client
        try await CustomModelDocumentWriter { method, params in
            try await client.requestValue(method, params)
        }.replace(document)
    }

    func restartGateway() async throws {
        struct Params: Codable { let commandId: String }
        struct Response: Decodable { let restarting: Bool }
        let _: Response = try await client.request("gateway.restart", Params(commandId: UUID().uuidString))
    }

    func loadWorkspace(path: String? = nil) async throws {
        struct Params: Codable { let path: String? }
        workspace = try await client.request("filesystem.list", Params(path: path), timeout: .seconds(30))
    }

    func createFolder(parent: String, name: String) async throws {
        struct Params: Codable { let parent, name, commandId: String }
        struct Response: Decodable { let path: String }
        let response: Response = try await client.request("filesystem.mkdir", Params(parent: parent, name: name, commandId: UUID().uuidString))
        try await loadWorkspace(path: parent)
        defaultWorkspace = response.path
    }

    func answerInteraction(_ interaction: ExtensionInteraction, value: JSONValue?, cancelled: Bool) async throws {
        guard let sessionID = selectedSessionID else { return }
        struct Params: Codable { let sessionId, interactionId: String; let value: JSONValue?; let cancelled: Bool; let commandId: String }
        struct Response: Decodable { let answered: Bool }
        let _: Response = try await client.request("extension.respond", Params(sessionId: sessionID, interactionId: interaction.id, value: value, cancelled: cancelled, commandId: UUID().uuidString))
    }

    func listTerminals() async throws -> [TerminalSummary] {
        guard let sessionID = selectedSessionID else { return [] }
        struct Params: Codable { let sessionId: String }
        struct Response: Decodable { let terminals: [TerminalSummary] }
        let response: Response = try await client.request("terminal.list", Params(sessionId: sessionID))
        terminals = response.terminals
        return response.terminals
    }

    func openTerminal(columns: Int, rows: Int) async throws -> TerminalSummary {
        guard let sessionID = selectedSessionID else { throw GatewayFailure(code: "no_session", message: "Select a session first.", retryable: false, details: nil) }
        struct Params: Codable { let sessionId: String; let columns, rows: Int; let commandId: String }
        struct Replay: Decodable { let terminal: TerminalSummary; let chunks: [TerminalChunk]; let reset: Bool }
        struct Response: Decodable { let terminal: TerminalSummary; let replay: Replay }
        let response: Response = try await client.request("terminal.open", Params(sessionId: sessionID, columns: columns, rows: rows, commandId: UUID().uuidString))
        terminalChunks[response.terminal.id] = response.replay.chunks
        return response.terminal
    }

    func attachTerminal(_ id: String, after: Int) async throws -> TerminalSummary {
        struct Params: Codable { let terminalId: String; let afterSequence: Int }
        struct Response: Decodable { let terminal: TerminalSummary; let chunks: [TerminalChunk]; let reset: Bool }
        let response: Response = try await client.request("terminal.attach", Params(terminalId: id, afterSequence: after))
        if response.reset { terminalChunks[id] = response.chunks }
        else { terminalChunks[id, default: []].append(contentsOf: response.chunks) }
        return response.terminal
    }

    func detachTerminal(_ id: String) async {
        struct Params: Codable { let terminalId: String }
        struct Response: Decodable { let detached: Bool }
        let _: Response? = try? await client.request("terminal.detach", Params(terminalId: id))
    }

    func writeTerminal(_ id: String, data: String) async throws {
        struct Params: Codable { let terminalId, writeId, data, commandId: String }
        struct Response: Decodable { let written: Bool }
        let identity = UUID().uuidString
        let _: Response = try await client.request("terminal.write", Params(terminalId: id, writeId: identity, data: data, commandId: identity))
    }

    func resizeTerminal(_ id: String, columns: Int, rows: Int) async throws {
        struct Params: Codable { let terminalId: String; let columns, rows: Int; let commandId: String }
        struct Response: Decodable { let resized: Bool }
        let _: Response = try await client.request("terminal.resize", Params(terminalId: id, columns: columns, rows: rows, commandId: UUID().uuidString))
    }

    func terminateTerminal(_ id: String) async throws {
        struct Params: Codable { let terminalId, commandId: String }
        struct Response: Decodable { let terminated: Bool }
        let _: Response = try await client.request("terminal.terminate", Params(terminalId: id, commandId: UUID().uuidString))
    }

    func handle(_ event: GatewayEvent) async {
        switch event.topic {
        case "transport.disconnected", "system.stopping":
            subscribedSessionID = nil
            connectionState = .reconnecting
            reconnectTask?.cancel()
            reconnectTask = nil
            scheduleReconnect()
        case "transport.resyncRequired":
            if let selectedSessionID { await requestResync(selectedSessionID) }
        case "session.listChanged":
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                await self?.refreshSessions()
            }
        case "session.snapshot":
            if let snapshot = try? event.payload.decode(SessionSnapshot.self) { apply(snapshot) }
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
                snapshot.toolExecutions[index] = tool
            } else {
                snapshot.toolExecutions.append(tool)
            }
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
            guard let (_, envelope) = admitSessionEvent(event) else { break }
            if let message = envelope.data.objectValue?["message"]?.stringValue { notifications.append(message) }
        case "session.operationFailed", "session.extensionError":
            guard let (_, envelope) = admitSessionEvent(event) else { break }
            if let message = envelope.data.objectValue?["message"]?.stringValue { lastError = message }
            else if case .string(let message) = envelope.data { lastError = message }
        case "session.compaction", "session.retry", "session.bashProgress":
            _ = admitSessionEvent(event)
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
        case "packages.progress", "packages.completed":
            notifications.append(event.topic == "packages.completed" ? "Package operation completed" : "Updating agent package…")
        case "terminal.output":
            if let object = event.payload.objectValue,
               let terminalID = object["terminalId"]?.stringValue,
               let sequence = object["sequence"]?.intValue,
               let data = object["data"]?.stringValue {
                terminalChunks[terminalID, default: []].append(TerminalChunk(sequence: sequence, data: data))
                if terminalChunks[terminalID, default: []].count > 2_048 {
                    terminalChunks[terminalID]?.removeFirst(terminalChunks[terminalID]!.count - 2_048)
                }
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
                        sequence: current.sequence
                    )
                }
            }
        default:
            break
        }
    }

    private func admitSessionEvent(_ event: GatewayEvent) -> (String, SessionEventEnvelope)? {
        guard let sessionID = event.sessionId,
              let envelope = try? event.payload.decode(SessionEventEnvelope.self),
              let snapshot = snapshots[sessionID] else { return nil }
        guard envelope.runtimeGeneration == snapshot.runtimeGeneration else {
            Task { await requestResync(sessionID) }
            return nil
        }
        guard envelope.eventSequence > snapshot.eventSequence else { return nil }
        guard envelope.eventSequence == snapshot.eventSequence + 1 else {
            Task { await requestResync(sessionID) }
            return nil
        }
        return (sessionID, envelope)
    }

    private func advance(_ snapshot: inout SessionSnapshot, _ envelope: SessionEventEnvelope) {
        snapshot.eventSequence = envelope.eventSequence
        snapshot.revision = max(snapshot.revision, envelope.revision)
    }

    private func requestResync(_ sessionID: String) async {
        guard !resyncingSessionIDs.contains(sessionID) else { return }
        resyncingSessionIDs.insert(sessionID)
        defer { resyncingSessionIDs.remove(sessionID) }
        do {
            struct Params: Codable { let sessionId: String }
            struct Response: Decodable { let session: SessionSnapshot }
            let response: Response = try await client.request("session.open", Params(sessionId: sessionID), timeout: .seconds(60))
            subscribedSessionID = sessionID
            apply(response.session)
        } catch { surface(error) }
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
        snapshots[snapshot.sessionId] = snapshot
        saveCache()
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

    private func confirmedMutation<Response: Decodable>(
        method: String,
        commandId: String,
        send: () async throws -> Response
    ) async throws -> Response {
        do { return try await send() }
        catch let original as GatewayFailure where original.retryable || original.code == "timeout" || original.code == "disconnected" {
            guard let status: CommandStatusResponse = try? await client.request(
                "command.status",
                CommandStatusParams(method: method, commandId: commandId)
            ) else {
                throw original
            }
            switch status.status {
            case "completed":
                guard let result = status.result else {
                    throw GatewayFailure(code: "invalid_response", message: "The completed command did not include a result.", retryable: false, details: nil)
                }
                return try result.decode(Response.self)
            case "missing":
                return try await send()
            default:
                throw GatewayFailure(
                    code: "outcome_unknown",
                    message: "Tron accepted this command but its result is still uncertain. Refresh the session before trying again.",
                    retryable: false,
                    details: .object(["commandId": .string(commandId), "method": .string(method)])
                )
            }
        }
    }

    private func surface(_ error: Error) {
        if error is CancellationError { return }
        lastError = error.localizedDescription
    }

    private func loadCache(profileID: String) async {
        let value = await cache.load(profileID: profileID)
        sessions = value.sessions
        snapshots = Dictionary(uniqueKeysWithValues: value.snapshots.map { ($0.sessionId, $0) })
        reconcileSelection()
    }

    private func saveCache() {
        guard let id = profiles.selected?.id else { return }
        let sessions = sessions
        let values = Array(snapshots.values)
        Task { await cache.save(profileID: id, sessions: sessions, snapshots: values) }
    }

    private struct MutationResponse: Decodable {
        let updated: Bool?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let object = try container.decode([String: Bool].self)
            updated = object.values.first
        }
    }
}
