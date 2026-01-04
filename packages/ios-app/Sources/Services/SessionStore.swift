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

    @Published var sessions: [StoredSession] = []
    @Published var activeSessionId: String?

    private var saveTask: Task<Void, Never>?
    private let saveDebounceMs: UInt64 = 500

    var activeSession: StoredSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var sortedSessions: [StoredSession] {
        sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    init() {
        loadSessions()
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
        saveImmediately()
    }

    func updateSession(id: String, update: (inout StoredSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        update(&sessions[index])
        debouncedSave()
    }

    func setActiveSession(_ sessionId: String?) {
        activeSessionId = sessionId

        // Update isActive flags
        for i in sessions.indices {
            sessions[i].isActive = sessions[i].id == sessionId
        }

        saveImmediately()
    }

    func deleteSession(_ sessionId: String) {
        sessions.removeAll { $0.id == sessionId }
        if activeSessionId == sessionId {
            activeSessionId = sessions.first?.id
        }
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
