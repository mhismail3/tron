import Foundation
import Observation

/// A Mac server paired to this iOS device.
///
/// The pairing itself is iOS-local: the server owns its runtime settings, while
/// the app owns the list of servers it knows how to reach and the Keychain
/// token for each server id.
struct PairedServer: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var label: String
    var host: String
    var port: Int
    var lastConnectedAt: Date?
    var lastKnownVersion: String?
    var lastKnownStatus: String?

    init(
        id: String,
        label: String,
        host: String,
        port: Int,
        lastConnectedAt: Date? = nil,
        lastKnownVersion: String? = nil,
        lastKnownStatus: String? = nil
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.lastConnectedAt = lastConnectedAt
        self.lastKnownVersion = lastKnownVersion
        self.lastKnownStatus = lastKnownStatus
    }

    var origin: String {
        "\(host):\(port)"
    }
}

/// iOS-local source of truth for paired servers and active selection.
///
/// There is intentionally no migration from the removed server-side pairing
/// model. A fresh store starts empty, which prevents the app from silently
/// dialing localhost when no server has been paired on this device.
@Observable
@MainActor
final class PairedServerStore {
    nonisolated static let serversKey = "pairedServers"
    nonisolated static let activeIdKey = "activePairedServerId"

    struct RemovalPlan: Equatable {
        let removedWasActive: Bool
        let nextActiveServer: PairedServer?
        let shouldReturnToOnboarding: Bool
    }

    private(set) var servers: [PairedServer]
    private(set) var activeServerId: String?

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.serversKey),
           let decoded = try? JSONDecoder().decode([PairedServer].self, from: data) {
            servers = Self.uniqued(decoded)
        } else {
            servers = []
        }
        activeServerId = defaults.string(forKey: Self.activeIdKey)
        normalizeActiveSelection()
    }

    var activeServer: PairedServer? {
        guard let activeServerId else { return nil }
        return servers.first { $0.id == activeServerId }
    }

    func replace(_ newServers: [PairedServer], activeId: String?) {
        servers = Self.uniqued(newServers)
        activeServerId = activeId
        normalizeActiveSelection()
        persist()
    }

    func select(_ server: PairedServer) {
        guard servers.contains(where: { $0.id == server.id }) else { return }
        activeServerId = server.id
        persist()
    }

    func remove(_ server: PairedServer) -> RemovalPlan {
        let removedWasActive = activeServerId == server.id
        servers.removeAll { $0.id == server.id }
        let nextActive = removedWasActive ? servers.first : activeServer
        activeServerId = nextActive?.id
        normalizeActiveSelection()
        persist()
        return RemovalPlan(
            removedWasActive: removedWasActive,
            nextActiveServer: removedWasActive ? activeServer : nil,
            shouldReturnToOnboarding: servers.isEmpty
        )
    }

    func updateMetadata(for serverId: String, _ mutate: (inout PairedServer) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        mutate(&servers[index])
        persist()
    }

    private func normalizeActiveSelection() {
        guard !servers.isEmpty else {
            activeServerId = nil
            persist()
            return
        }
        if let activeServerId, servers.contains(where: { $0.id == activeServerId }) {
            persist()
            return
        }
        activeServerId = servers[0].id
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.serversKey)
        }
        if let activeServerId {
            defaults.set(activeServerId, forKey: Self.activeIdKey)
        } else {
            defaults.removeObject(forKey: Self.activeIdKey)
        }
    }

    private static func uniqued(_ servers: [PairedServer]) -> [PairedServer] {
        var seen: Set<String> = []
        var result: [PairedServer] = []
        for server in servers where !seen.contains(server.id) {
            seen.insert(server.id)
            result.append(server)
        }
        return result
    }
}
