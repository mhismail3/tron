import Foundation

/// `UserDefaults` is documented as thread-safe. This narrow unchecked wrapper
/// admits only the installation scalar and one-time legacy migration into the
/// notification store actor; ordinary notification state never returns there.
struct NotificationDefaultsHandle: @unchecked Sendable {
    let value: UserDefaults
}

struct NotificationLocalState: Codable, Equatable, Sendable {
    var inbox: [NotificationInboxItem] = []
    var outbox: [NotificationMutation] = []
    var readiness: [NotificationServerReadiness] = []
}

/// Serial durable owner for the native notification projection and mutation
/// outbox. State is written atomically outside the main actor; APNs tokens are
/// never admitted. The legacy whole-array defaults keys are migrated once
/// after the first successful file write.
actor NotificationLocalStore {
    private enum LegacyKey {
        static let installationId = "nativeNotifications.installationId"
        static let inbox = "nativeNotifications.inbox.v1"
        static let outbox = "nativeNotifications.outbox.v1"
        static let readiness = "nativeNotifications.readiness.v1"
    }

    nonisolated let installationId: String

    private let defaults: UserDefaults
    private let fileURL: URL
    private var state: NotificationLocalState?

    init(defaults: NotificationDefaultsHandle, fileURL: URL) {
        self.defaults = defaults.value
        self.fileURL = fileURL
        if let existing = defaults.value.string(
            forKey: LegacyKey.installationId
        ),
           !existing.isEmpty {
            installationId = existing
        } else {
            let created = UUID().uuidString.lowercased()
            defaults.value.set(created, forKey: LegacyKey.installationId)
            installationId = created
        }
    }

    func load() throws -> NotificationLocalState {
        try loadIfNeeded()
    }

    /// Persist a response batch in one atomic write. Mutation identifiers are
    /// idempotent so repeated UI callbacks or a restore merge cannot duplicate
    /// the durable outbox.
    func appendMutations(
        _ mutations: [NotificationMutation]
    ) throws -> NotificationLocalState {
        var current = try loadIfNeeded()
        var admittedIds = Set(current.outbox.map(\.mutationId))
        let admitted = mutations.filter {
            admittedIds.insert($0.mutationId).inserted
        }
        guard !admitted.isEmpty else { return current }
        current.outbox.append(contentsOf: admitted)
        Self.applyOptimisticMutations(current.outbox, to: &current.inbox)
        try persist(current)
        state = current
        return current
    }

    func replaceReadiness(
        _ readiness: [NotificationServerReadiness]
    ) throws -> NotificationLocalState {
        var current = try loadIfNeeded()
        current.readiness = readiness
        try persist(current)
        state = current
        return current
    }

    /// Commit one or more authoritative server pages and response receipts in
    /// one file transaction. Still-pending responses are replayed over the
    /// server projection so a newer optimistic action cannot flicker back to
    /// unread while another synchronization was in flight.
    func commitSynchronization(
        acknowledgedMutationIds: Set<String>,
        deliveriesByServer: [String: [NotificationDeliveryDTO]]
    ) throws -> NotificationLocalState {
        var current = try loadIfNeeded()
        if !acknowledgedMutationIds.isEmpty {
            current.outbox.removeAll {
                acknowledgedMutationIds.contains($0.mutationId)
            }
        }
        for (serverId, deliveries) in deliveriesByServer {
            current.inbox.removeAll { $0.serverId == serverId }
            current.inbox.append(contentsOf: deliveries.map {
                NotificationInboxItem(serverId: serverId, delivery: $0)
            })
        }
        Self.applyOptimisticMutations(current.outbox, to: &current.inbox)
        current.inbox.sort {
            $0.delivery.createdAt > $1.delivery.createdAt
        }
        try persist(current)
        state = current
        return current
    }

    private func loadIfNeeded() throws -> NotificationLocalState {
        if let state { return state }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode(
                    NotificationLocalState.self,
                    from: data
                )
                state = decoded
                return decoded
            } catch {
                // Preserve corrupt evidence for diagnostics while allowing the
                // app to recover and re-synchronize from paired engines.
                let quarantineURL = fileURL
                    .deletingPathExtension()
                    .appendingPathExtension("corrupt-\(UUID().uuidString).json")
                try? FileManager.default.moveItem(
                    at: fileURL,
                    to: quarantineURL
                )
            }
        }

        let migrated = NotificationLocalState(
            inbox: decodeLegacy([NotificationInboxItem].self, key: LegacyKey.inbox) ?? [],
            outbox: decodeLegacy([NotificationMutation].self, key: LegacyKey.outbox) ?? [],
            readiness: decodeLegacy(
                [NotificationServerReadiness].self,
                key: LegacyKey.readiness
            ) ?? []
        )
        let hadLegacyState = defaults.object(forKey: LegacyKey.inbox) != nil
            || defaults.object(forKey: LegacyKey.outbox) != nil
            || defaults.object(forKey: LegacyKey.readiness) != nil
        if hadLegacyState {
            try persist(migrated)
            defaults.removeObject(forKey: LegacyKey.inbox)
            defaults.removeObject(forKey: LegacyKey.outbox)
            defaults.removeObject(forKey: LegacyKey.readiness)
        }
        state = migrated
        return migrated
    }

    private func persist(_ value: NotificationLocalState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(value)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func decodeLegacy<T: Decodable>(
        _ type: T.Type,
        key: String
    ) -> T? {
        defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(type, from: $0)
        }
    }

    private static func applyOptimisticMutations(
        _ mutations: [NotificationMutation],
        to inbox: inout [NotificationInboxItem]
    ) {
        for mutation in mutations {
            guard let index = inbox.firstIndex(where: {
                $0.serverId == mutation.serverId
                    && $0.delivery.deliveryId == mutation.deliveryId
            }) else { continue }
            inbox[index].delivery.readAt =
                inbox[index].delivery.readAt ?? mutation.occurredAt
            if mutation.acknowledgement != .clearUnread {
                inbox[index].delivery.terminalResponse =
                    mutation.acknowledgement.rawValue
                inbox[index].delivery.terminalRespondedAt =
                    mutation.occurredAt
            }
        }
    }
}
