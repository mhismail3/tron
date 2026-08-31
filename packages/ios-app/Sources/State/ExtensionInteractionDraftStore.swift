import Foundation

struct StoredExtensionInteractionScope: Codable, Hashable, Sendable {
    let sessionID: String
    let interactionID: String
    let hostEpoch: String
    let presentationRevision: Int

    init(sessionID: String, interaction: ExtensionInteraction) {
        self.sessionID = sessionID
        interactionID = interaction.id
        hostEpoch = interaction.hostEpoch
        presentationRevision = interaction.presentationRevision
    }
}

struct StoredExtensionFormDraft: Codable, Equatable, Sendable {
    let draft: ExtensionFormDraft
    let activeOtherQuestionIDs: Set<String>
    let currentQuestionIndex: Int
}

struct StoredPrimitiveInteractionDraft: Codable, Equatable, Sendable {
    let text: String
    let selectedOption: String?
    let confirmValue: Bool?
}

/// Bounded local ownership for answers the user has not submitted yet. Gateway
/// interaction state remains authoritative; this store contains only disposable
/// device-local drafts.
@MainActor
final class ExtensionInteractionDraftStore {
    static let documentKey = "extension.interactionDrafts.v1"
    private static let version = 1
    private static let maximumEntries = 32
    private static let maximumDocumentBytes = 768 * 1_024
    private static let maximumIdentityBytes = 512

    private struct Entry: Codable, Sendable {
        let scope: StoredExtensionInteractionScope
        var updatedAt: TimeInterval
        var form: StoredExtensionFormDraft?
        var primitive: StoredPrimitiveInteractionDraft?
    }

    private struct Document: Codable, Sendable {
        let version: Int
        let entries: [Entry]
    }

    private let defaults: UserDefaults
    private var entries: [StoredExtensionInteractionScope: Entry] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func formDraft(sessionID: String, interaction: ExtensionInteraction) -> StoredExtensionFormDraft? {
        entries[scope(sessionID: sessionID, interaction: interaction)]?.form
    }

    func primitiveDraft(sessionID: String, interaction: ExtensionInteraction) -> StoredPrimitiveInteractionDraft? {
        entries[scope(sessionID: sessionID, interaction: interaction)]?.primitive
    }

    func saveForm(
        _ form: StoredExtensionFormDraft,
        sessionID: String,
        interaction: ExtensionInteraction
    ) {
        let key = scope(sessionID: sessionID, interaction: interaction)
        guard admits(key), admits(form, interaction: interaction) else { return }
        var entry = entries[key] ?? Entry(
            scope: key,
            updatedAt: Date().timeIntervalSince1970,
            form: nil,
            primitive: nil
        )
        entry.updatedAt = Date().timeIntervalSince1970
        entry.form = form
        entry.primitive = nil
        entries[key] = entry
        persist(retaining: key)
    }

    func savePrimitive(
        _ primitive: StoredPrimitiveInteractionDraft,
        sessionID: String,
        interaction: ExtensionInteraction
    ) {
        let key = scope(sessionID: sessionID, interaction: interaction)
        guard admits(key), admits(primitive, interaction: interaction) else { return }
        var entry = entries[key] ?? Entry(
            scope: key,
            updatedAt: Date().timeIntervalSince1970,
            form: nil,
            primitive: nil
        )
        entry.updatedAt = Date().timeIntervalSince1970
        entry.form = nil
        entry.primitive = primitive
        entries[key] = entry
        persist(retaining: key)
    }

    func clear(sessionID: String, interaction: ExtensionInteraction) {
        entries.removeValue(forKey: scope(sessionID: sessionID, interaction: interaction))
        persist()
    }

    func removeAll() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.documentKey)
    }

    func reconcile(sessionID: String, pendingInteractions: [ExtensionInteraction]) {
        let pending = Set(pendingInteractions.map { scope(sessionID: sessionID, interaction: $0) })
        let stale = entries.keys.filter { $0.sessionID == sessionID && !pending.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale { entries.removeValue(forKey: key) }
        persist()
    }

    private func scope(sessionID: String, interaction: ExtensionInteraction) -> StoredExtensionInteractionScope {
        StoredExtensionInteractionScope(sessionID: sessionID, interaction: interaction)
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.documentKey) else { return }
        guard data.count <= Self.maximumDocumentBytes,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.version,
              document.entries.count <= Self.maximumEntries else {
            defaults.removeObject(forKey: Self.documentKey)
            return
        }
        var admitted: [StoredExtensionInteractionScope: Entry] = [:]
        for entry in document.entries where admits(entry.scope) && admits(entry) {
            guard admitted[entry.scope] == nil else {
                defaults.removeObject(forKey: Self.documentKey)
                entries = [:]
                return
            }
            admitted[entry.scope] = entry
        }
        entries = admitted
    }

    private func persist(retaining retained: StoredExtensionInteractionScope? = nil) {
        trimToCount(retaining: retained)
        while true {
            let ordered = entries.values.sorted { $0.updatedAt > $1.updatedAt }
            let document = Document(version: Self.version, entries: ordered)
            guard let data = try? JSONEncoder().encode(document) else { return }
            if data.count <= Self.maximumDocumentBytes {
                defaults.set(data, forKey: Self.documentKey)
                return
            }
            guard let oldest = ordered.reversed().first(where: { $0.scope != retained }) else {
                entries.removeAll()
                defaults.removeObject(forKey: Self.documentKey)
                return
            }
            entries.removeValue(forKey: oldest.scope)
        }
    }

    private func trimToCount(retaining retained: StoredExtensionInteractionScope?) {
        while entries.count > Self.maximumEntries {
            guard let oldest = entries.values
                .filter({ $0.scope != retained })
                .min(by: { $0.updatedAt < $1.updatedAt }) else { break }
            entries.removeValue(forKey: oldest.scope)
        }
    }

    private func admits(_ scope: StoredExtensionInteractionScope) -> Bool {
        !scope.sessionID.isEmpty
            && scope.sessionID.utf8.count <= Self.maximumIdentityBytes
            && !scope.interactionID.isEmpty
            && scope.interactionID.utf8.count <= Self.maximumIdentityBytes
            && !scope.hostEpoch.isEmpty
            && scope.hostEpoch.utf8.count <= Self.maximumIdentityBytes
            && scope.presentationRevision > 0
    }

    private func admits(_ entry: Entry) -> Bool {
        entry.updatedAt.isFinite
            && (entry.form == nil || entry.primitive == nil)
            && (entry.form.map { form in
                form.currentQuestionIndex >= 0
                    && form.currentQuestionIndex < 4
                    && form.activeOtherQuestionIDs.count <= 4
                    && form.activeOtherQuestionIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
                    && (try? JSONEncoder().encode(form).count).map { $0 <= ExtensionInteractionResponsePolicy.maximumResponseBytes } == true
            } ?? true)
            && (entry.primitive.map { primitive in
                primitive.text.utf8.count <= ExtensionInteractionResponsePolicy.maximumResponseBytes
                    && (primitive.selectedOption?.utf8.count ?? 0) <= 2 * 1_024
            } ?? true)
    }

    private func admits(_ stored: StoredExtensionFormDraft, interaction: ExtensionInteraction) -> Bool {
        guard let descriptor = interaction.form,
              descriptor.questions.indices.contains(stored.currentQuestionIndex),
              stored.activeOtherQuestionIDs.isSubset(of: Set(descriptor.questions.filter(\.allowOther).map(\.id))) else {
            return false
        }
        let restored = ExtensionFormDraft(restoring: stored.draft, for: descriptor)
        return restored == stored.draft
    }

    private func admits(_ stored: StoredPrimitiveInteractionDraft, interaction: ExtensionInteraction) -> Bool {
        switch interaction.method {
        case .select:
            return stored.text.isEmpty
                && stored.confirmValue == nil
                && stored.selectedOption.map { interaction.options?.contains($0) == true } ?? true
        case .confirm:
            return stored.text.isEmpty && stored.selectedOption == nil
        case .input, .editor:
            return stored.selectedOption == nil
                && stored.confirmValue == nil
                && ExtensionInteractionResponsePolicy.primitiveTextError(stored.text) == nil
        case .form:
            return false
        }
    }
}
