import Foundation

/// Coordinates persisting and restoring chat input draft state per session.
///
/// Uses SQLite for lightweight metadata (text and attachment metadata)
/// and the file system for attachment binary data. Supports debounced saving
/// during active editing and immediate saving on view disappear.
@Observable
@MainActor
final class DraftStore {

    private let eventDatabase: EventDatabase
    private let draftsRootURL: URL
    private let attachmentFiles: DraftAttachmentFileStore

    // MARK: - Debounce State

    private var debounceTask: Task<Void, Never>?
    private var lastSavedFingerprints: [String: Int] = [:]
    private static let debounceInterval: Duration = .milliseconds(500)
    private var pendingSessionId: String?
    private var pendingInputBarState: InputBarState?
    private var textEndRevealSessionIds: Set<String> = []
    private var userInputDebounceTasks: [String: Task<Void, Never>] = [:]
    private var pendingUserInputDrafts: [String: (sessionId: String, invocationId: String, draft: UserInputDraft)] = [:]
    private static let userInputDebounceInterval: Duration = .milliseconds(200)

    init(eventDatabase: EventDatabase, documentsURL: URL) {
        self.eventDatabase = eventDatabase
        let draftsRootURL = documentsURL
            .appendingPathComponent(".tron", isDirectory: true)
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("drafts", isDirectory: true)
        self.draftsRootURL = draftsRootURL
        self.attachmentFiles = DraftAttachmentFileStore(rootURL: draftsRootURL)
    }

    // MARK: - Public API

    /// Schedule a debounced save. Rapid calls within 500ms are coalesced.
    func scheduleSave(sessionId: String, inputBarState: InputBarState) {
        pendingSessionId = sessionId
        pendingInputBarState = inputBarState

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: DraftStore.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.performSave(sessionId: sessionId, inputBarState: inputBarState)
        }
    }

    /// Save immediately, bypassing debounce. Use on `onDisappear`.
    func saveImmediately(sessionId: String, inputBarState: InputBarState) async {
        debounceTask?.cancel()
        debounceTask = nil
        pendingSessionId = nil
        pendingInputBarState = nil
        await performSave(sessionId: sessionId, inputBarState: inputBarState)
    }

    /// Load a draft into the given InputBarState. Returns true if a draft was found.
    @discardableResult
    func loadDraft(
        sessionId: String,
        into inputBarState: InputBarState,
        ifUnchangedFrom expectedFingerprint: Int? = nil
    ) async -> Bool {
        guard eventDatabase.isInitialized else { return false }

        do {
            guard let draft = try await eventDatabase.drafts.load(sessionId: sessionId) else {
                return false
            }

            let attachments = await attachmentFiles.read(
                sessionId: sessionId,
                metadata: draft.attachmentMetadata
            )
            guard !Task.isCancelled else { return false }
            if let expectedFingerprint,
               inputBarState.draftFingerprint != expectedFingerprint {
                logger.debug(
                    "Skipped stale draft restore because the composer changed while loading",
                    category: .database
                )
                return false
            }

            // Publish draft text and attachments only after every async read is
            // complete and the mounted composer still matches its initial cut.
            inputBarState.text = draft.text
            inputBarState.attachments = attachments
            if textEndRevealSessionIds.remove(sessionId) != nil {
                inputBarState.requestTextEndReveal()
            }
            lastSavedFingerprints[sessionId] = inputBarState.draftFingerprint

            return true
        } catch {
            logger.warning("Failed to load draft for session \(sessionId): \(error.localizedDescription)", category: .database)
            return false
        }
    }

    /// Marks an externally prepared draft so the next mounted composer reveals
    /// its editable tail without changing focus or opening the keyboard.
    func revealTextEndOnNextLoad(sessionId: String) {
        textEndRevealSessionIds.insert(sessionId)
    }

    /// Clear a draft after sending a message.
    func clearDraft(sessionId: String) async {
        lastSavedFingerprints.removeValue(forKey: sessionId)
        textEndRevealSessionIds.remove(sessionId)
        do {
            try await eventDatabase.drafts.delete(sessionId: sessionId)
        } catch {
            logger.warning("Failed to delete draft row for session \(sessionId): \(error.localizedDescription)", category: .database)
        }
        await attachmentFiles.remove(sessionId: sessionId)
    }

    /// Clean up a draft when a session is deleted.
    func deleteSessionDraft(sessionId: String) async {
        await clearDraft(sessionId: sessionId)
        let prefix = "\(sessionId)\u{1f}"
        for key in userInputDebounceTasks.keys.filter({ $0.hasPrefix(prefix) }) {
            userInputDebounceTasks.removeValue(forKey: key)?.cancel()
            pendingUserInputDrafts.removeValue(forKey: key)
        }
        do {
            try await eventDatabase.userInputDrafts.deleteSession(sessionId)
        } catch {
            logger.warning(
                "Failed to delete question drafts for session \(sessionId): \(error.localizedDescription)",
                category: .database
            )
        }
    }

    /// Flush any pending debounced save. Call on app background.
    func flushPending() async {
        if let sessionId = pendingSessionId, let state = pendingInputBarState {
            await saveImmediately(sessionId: sessionId, inputBarState: state)
        }
        let pending = Array(pendingUserInputDrafts.values)
        pendingUserInputDrafts.removeAll()
        for task in userInputDebounceTasks.values { task.cancel() }
        userInputDebounceTasks.removeAll()
        for value in pending {
            await saveUserInputDraftImmediately(
                sessionId: value.sessionId,
                invocationId: value.invocationId,
                draft: value.draft
            )
        }
    }

    // MARK: - Question Drafts

    func loadUserInputDraft(sessionId: String, request: UserInputRequest) async -> UserInputDraft? {
        guard eventDatabase.isInitialized else { return nil }
        do {
            return try await eventDatabase.userInputDrafts.load(
                sessionId: sessionId,
                invocationId: request.invocationId
            )?.reconciled(with: request)
        } catch {
            logger.warning(
                "Failed to load question draft for \(request.invocationId): \(error.localizedDescription)",
                category: .database
            )
            return nil
        }
    }

    func scheduleUserInputDraftSave(
        sessionId: String,
        invocationId: String,
        draft: UserInputDraft
    ) {
        let key = userInputKey(sessionId: sessionId, invocationId: invocationId)
        pendingUserInputDrafts[key] = (sessionId, invocationId, draft)
        userInputDebounceTasks[key]?.cancel()
        userInputDebounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: DraftStore.userInputDebounceInterval)
            guard !Task.isCancelled else { return }
            await self?.flushUserInputDraft(key: key)
        }
    }

    func saveUserInputDraft(
        sessionId: String,
        invocationId: String,
        draft: UserInputDraft
    ) async {
        let key = userInputKey(sessionId: sessionId, invocationId: invocationId)
        userInputDebounceTasks.removeValue(forKey: key)?.cancel()
        pendingUserInputDrafts.removeValue(forKey: key)
        await saveUserInputDraftImmediately(
            sessionId: sessionId,
            invocationId: invocationId,
            draft: draft
        )
    }

    func clearUserInputDraft(sessionId: String, invocationId: String) async {
        let key = userInputKey(sessionId: sessionId, invocationId: invocationId)
        userInputDebounceTasks.removeValue(forKey: key)?.cancel()
        pendingUserInputDrafts.removeValue(forKey: key)
        do {
            try await eventDatabase.userInputDrafts.delete(
                sessionId: sessionId,
                invocationId: invocationId
            )
        } catch {
            logger.warning(
                "Failed to clear question draft for \(invocationId): \(error.localizedDescription)",
                category: .database
            )
        }
    }

    // MARK: - File Paths

    func draftsDirectory(for sessionId: String) -> URL {
        draftsRootURL.appendingPathComponent(sessionId, isDirectory: true)
    }

    func removeAllDraftFiles() {
        try? FileManager.default.removeItem(at: draftsRootURL)
    }

    // MARK: - Private

    private func performSave(sessionId: String, inputBarState: InputBarState) async {
        guard eventDatabase.isInitialized else { return }

        let fingerprint = inputBarState.draftFingerprint
        if lastSavedFingerprints[sessionId] == fingerprint {
            return
        }

        guard inputBarState.hasContent else {
            if lastSavedFingerprints[sessionId] != nil {
                await clearDraft(sessionId: sessionId)
            }
            return
        }

        do {
            let attachmentMetadata = inputBarState.attachments.map { attachment in
                DraftAttachmentMetadata(
                    id: attachment.id,
                    type: attachment.type,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName,
                    originalSize: attachment.originalSize,
                    wasConverted: attachment.wasConverted,
                    originalMimeType: attachment.originalMimeType
                )
            }

            try await eventDatabase.drafts.save(
                sessionId: sessionId,
                text: inputBarState.text,
                attachmentMetadata: attachmentMetadata
            )

            try await attachmentFiles.write(
                sessionId: sessionId,
                attachments: inputBarState.attachments
            )

            lastSavedFingerprints[sessionId] = fingerprint
        } catch {
            logger.warning("Failed to save draft for session \(sessionId): \(error.localizedDescription)", category: .database)
        }
    }

    private func flushUserInputDraft(key: String) async {
        guard let pending = pendingUserInputDrafts.removeValue(forKey: key) else { return }
        userInputDebounceTasks.removeValue(forKey: key)
        await saveUserInputDraftImmediately(
            sessionId: pending.sessionId,
            invocationId: pending.invocationId,
            draft: pending.draft
        )
    }

    private func saveUserInputDraftImmediately(
        sessionId: String,
        invocationId: String,
        draft: UserInputDraft
    ) async {
        guard eventDatabase.isInitialized else { return }
        do {
            try await eventDatabase.userInputDrafts.save(
                sessionId: sessionId,
                invocationId: invocationId,
                draft: draft
            )
        } catch {
            logger.warning(
                "Failed to save question draft for \(invocationId): \(error.localizedDescription)",
                category: .database
            )
        }
    }

    private func userInputKey(sessionId: String, invocationId: String) -> String {
        "\(sessionId)\u{1f}\(invocationId)"
    }

}

/// Serial file-I/O owner for attachment payloads. Draft metadata remains in
/// the existing database actor while potentially large binary reads and writes
/// never block SwiftUI's main actor.
private actor DraftAttachmentFileStore {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func directory(for sessionId: String) -> URL {
        rootURL.appendingPathComponent(sessionId, isDirectory: true)
    }

    func write(sessionId: String, attachments: [Attachment]) throws {
        let dir = directory(for: sessionId)
        let fm = FileManager.default

        if !attachments.isEmpty {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let currentIds = Set(attachments.map { $0.id.uuidString })
        for attachment in attachments {
            let filePath = dir.appendingPathComponent("\(attachment.id.uuidString).dat")
            try attachment.data.write(to: filePath)
        }

        if let existingFiles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                let stem = file.deletingPathExtension().lastPathComponent
                if !currentIds.contains(stem) {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    func read(
        sessionId: String,
        metadata: [DraftAttachmentMetadata]
    ) -> [Attachment] {
        let dir = directory(for: sessionId)
        var attachments: [Attachment] = []

        for meta in metadata {
            let filePath = dir.appendingPathComponent("\(meta.id.uuidString).dat")
            guard let data = try? Data(contentsOf: filePath) else {
                logger.warning("Draft attachment file missing: \(filePath.lastPathComponent) for session \(sessionId)", category: .database)
                continue
            }

            attachments.append(Attachment(
                id: meta.id,
                type: meta.type,
                data: data,
                mimeType: meta.mimeType,
                fileName: meta.fileName,
                originalSize: meta.originalSize,
                wasConverted: meta.wasConverted,
                originalMimeType: meta.originalMimeType
            ))
        }

        return attachments
    }

    func remove(sessionId: String) {
        let dir = directory(for: sessionId)
        try? FileManager.default.removeItem(at: dir)
    }
}
