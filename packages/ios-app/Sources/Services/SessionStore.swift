import Foundation
import Combine
import os

// MARK: - Stored Session

struct StoredSession: Codable, Identifiable, Hashable {
    let id: String  // sessionId
    var title: String
    var model: String
    var messageCount: Int
    var workingDirectory: String
    var createdAt: Date
    var lastActivity: Date
    var isActive: Bool
    var inputTokens: Int
    var outputTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }

    var displayTitle: String {
        if title.isEmpty {
            return URL(fileURLWithPath: workingDirectory).lastPathComponent
        }
        return title
    }

    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActivity, relativeTo: Date())
    }

    var shortModel: String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    init(
        id: String,
        title: String = "",
        model: String,
        messageCount: Int = 0,
        workingDirectory: String,
        createdAt: Date = Date(),
        lastActivity: Date = Date(),
        isActive: Bool = true,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.messageCount = messageCount
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.isActive = isActive
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

// MARK: - Session Store

@MainActor
class SessionStore: ObservableObject {
    private let logger = Logger(subsystem: "com.tron.mobile", category: "SessionStore")
    private let storageKey = "tron.sessions"
    private let activeSessionKey = "tron.activeSessionId"
    private let messagesStorageKey = "tron.sessionMessages"

    @Published var sessions: [StoredSession] = []
    @Published var activeSessionId: String?

    private var saveTask: Task<Void, Never>?
    private let saveDebounceMs: UInt64 = 500

    // MARK: - Cached Computed Properties (Performance Optimization)

    /// Cached sorted sessions - recomputed only when sessions change
    @Published private(set) var sortedSessions: [StoredSession] = []

    /// Cached active session lookup
    private var _activeSession: StoredSession?

    var activeSession: StoredSession? {
        if let id = activeSessionId {
            // Use cached value if still valid
            if _activeSession?.id == id {
                return _activeSession
            }
            _activeSession = sessions.first { $0.id == id }
            return _activeSession
        }
        _activeSession = nil
        return nil
    }

    /// Session messages storage (for persistence)
    private var sessionMessages: [String: [StoredMessage]] = [:]

    init() {
        loadSessions()
        loadSessionMessages()
    }

    // MARK: - Session Messages Persistence

    struct StoredMessage: Codable, Identifiable {
        let id: UUID
        let role: String
        let content: String
        let timestamp: Date
        let toolName: String?
        let toolResult: String?
    }

    func getMessages(for sessionId: String) -> [StoredMessage] {
        sessionMessages[sessionId] ?? []
    }

    func saveMessages(_ messages: [StoredMessage], for sessionId: String) {
        sessionMessages[sessionId] = messages
        debouncedSaveMessages()
    }

    func appendMessage(_ message: StoredMessage, for sessionId: String) {
        if sessionMessages[sessionId] == nil {
            sessionMessages[sessionId] = []
        }
        sessionMessages[sessionId]?.append(message)
        debouncedSaveMessages()
    }

    func clearMessages(for sessionId: String) {
        sessionMessages.removeValue(forKey: sessionId)
        debouncedSaveMessages()
    }

    private func loadSessionMessages() {
        if let data = UserDefaults.standard.data(forKey: messagesStorageKey) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                sessionMessages = try decoder.decode([String: [StoredMessage]].self, from: data)
                logger.info("Loaded messages for \(self.sessionMessages.count) sessions")
            } catch {
                logger.error("Failed to decode session messages: \(error.localizedDescription)")
                sessionMessages = [:]
            }
        }
    }

    private func saveSessionMessages() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessionMessages)
            UserDefaults.standard.set(data, forKey: messagesStorageKey)
            logger.debug("Saved messages for \(self.sessionMessages.count) sessions")
        } catch {
            logger.error("Failed to encode session messages: \(error.localizedDescription)")
        }
    }

    private var saveMessagesTask: Task<Void, Never>?

    private func debouncedSaveMessages() {
        saveMessagesTask?.cancel()
        saveMessagesTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            saveSessionMessages()
        }
    }

    /// Recompute cached sorted sessions
    private func updateSortedSessions() {
        sortedSessions = sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Persistence

    private func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                sessions = try decoder.decode([StoredSession].self, from: data)
                logger.info("Loaded \(self.sessions.count) sessions from storage")
            } catch {
                logger.error("Failed to decode sessions: \(error.localizedDescription)")
                sessions = []
            }
        }

        activeSessionId = UserDefaults.standard.string(forKey: activeSessionKey)
        updateSortedSessions()
    }

    private func saveSessions() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            UserDefaults.standard.set(data, forKey: storageKey)

            if let activeId = activeSessionId {
                UserDefaults.standard.set(activeId, forKey: activeSessionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeSessionKey)
            }

            logger.debug("Saved \(self.sessions.count) sessions")
        } catch {
            logger.error("Failed to encode sessions: \(error.localizedDescription)")
        }
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: saveDebounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            saveSessions()
        }
    }

    func saveImmediately() {
        saveTask?.cancel()
        saveSessions()
    }

    // MARK: - Session Management

    func addSession(_ session: StoredSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        activeSessionId = session.id
        _activeSession = session
        updateSortedSessions()
        saveImmediately()
    }

    func updateSession(id: String, update: (inout StoredSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        update(&sessions[index])
        // Invalidate cache if active session was updated
        if id == activeSessionId {
            _activeSession = sessions[index]
        }
        updateSortedSessions()
        debouncedSave()
    }

    func setActiveSession(_ sessionId: String?) {
        activeSessionId = sessionId
        _activeSession = nil // Invalidate cache

        // Update isActive flags
        for i in sessions.indices {
            sessions[i].isActive = sessions[i].id == sessionId
        }

        saveImmediately()
    }

    func deleteSession(_ sessionId: String) {
        sessions.removeAll { $0.id == sessionId }
        // Also delete stored messages for this session
        clearMessages(for: sessionId)
        if activeSessionId == sessionId {
            activeSessionId = sessions.first?.id
            _activeSession = nil
        }
        updateSortedSessions()
        saveImmediately()
    }

    func incrementMessageCount(for sessionId: String) {
        updateSession(id: sessionId) { session in
            session.messageCount += 1
            session.lastActivity = Date()
        }
    }

    func updateTokenUsage(for sessionId: String, input: Int, output: Int) {
        updateSession(id: sessionId) { session in
            session.inputTokens += input
            session.outputTokens += output
            session.lastActivity = Date()
        }
    }

    func setTitle(for sessionId: String, title: String) {
        updateSession(id: sessionId) { session in
            session.title = title
        }
    }

    func sessionExists(_ sessionId: String) -> Bool {
        sessions.contains { $0.id == sessionId }
    }

    func clearAllSessions() {
        sessions = []
        activeSessionId = nil
        saveImmediately()
    }
}
