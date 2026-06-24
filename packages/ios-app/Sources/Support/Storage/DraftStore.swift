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

    // MARK: - Debounce State

    private var debounceTask: Task<Void, Never>?
    private var lastSavedFingerprints: [String: Int] = [:]
    private static let debounceInterval: Duration = .milliseconds(500)
    private var pendingSessionId: String?
    private var pendingInputBarState: InputBarState?

    init(eventDatabase: EventDatabase, documentsURL: URL) {
        self.eventDatabase = eventDatabase
        self.draftsRootURL = documentsURL
            .appendingPathComponent(".tron", isDirectory: true)
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("drafts", isDirectory: true)
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
    func loadDraft(sessionId: String, into inputBarState: InputBarState) async -> Bool {
        guard eventDatabase.isInitialized else { return false }

        do {
            guard let draft = try await eventDatabase.drafts.load(sessionId: sessionId) else {
                return false
            }

            inputBarState.text = draft.text
            inputBarState.attachments = readAttachmentData(sessionId: sessionId, metadata: draft.attachmentMetadata)
            lastSavedFingerprints[sessionId] = inputBarState.draftFingerprint

            return true
        } catch {
            logger.warning("Failed to load draft for session \(sessionId): \(error.localizedDescription)", category: .database)
            return false
        }
    }

    /// Clear a draft after sending a message.
    func clearDraft(sessionId: String) async {
        lastSavedFingerprints.removeValue(forKey: sessionId)
        do {
            try await eventDatabase.drafts.delete(sessionId: sessionId)
        } catch {
            logger.warning("Failed to delete draft row for session \(sessionId): \(error.localizedDescription)", category: .database)
        }
        removeAttachmentFiles(sessionId: sessionId)
    }

    /// Clean up a draft when a session is deleted.
    func deleteSessionDraft(sessionId: String) async {
        await clearDraft(sessionId: sessionId)
    }

    /// Flush any pending debounced save. Call on app background.
    func flushPending() async {
        guard let sessionId = pendingSessionId, let state = pendingInputBarState else { return }
        await saveImmediately(sessionId: sessionId, inputBarState: state)
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

        guard inputBarState.hasDraftContent else {
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

            try writeAttachmentFiles(sessionId: sessionId, attachments: inputBarState.attachments)

            lastSavedFingerprints[sessionId] = fingerprint
        } catch {
            logger.warning("Failed to save draft for session \(sessionId): \(error.localizedDescription)", category: .database)
        }
    }

    private func writeAttachmentFiles(sessionId: String, attachments: [Attachment]) throws {
        let dir = draftsDirectory(for: sessionId)
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

    private func readAttachmentData(sessionId: String, metadata: [DraftAttachmentMetadata]) -> [Attachment] {
        let dir = draftsDirectory(for: sessionId)
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

    private func removeAttachmentFiles(sessionId: String) {
        let dir = draftsDirectory(for: sessionId)
        try? FileManager.default.removeItem(at: dir)
    }
}
