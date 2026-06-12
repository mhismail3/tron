import Foundation

// MARK: - Settings Methods

/// Server-authoritative settings decoded from `settings::get`.
///
/// This mirrors the primitive server settings surface. Product policy planes
/// and fixed workflow settings are intentionally absent.
struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    let tailscaleIp: String?

    let compaction: CompactionSettings

    let observabilityLogLevel: String
    let observabilityVerboseRetentionDays: UInt64
    let storageRetentionEnabled: Bool
    let storageMaxDatabaseMb: UInt64

    private enum CodingKeys: String, CodingKey {
        case server, context, observability, storage
    }

    private enum ServerKeys: String, CodingKey {
        case defaultModel, defaultWorkspace, tailscaleIp
    }

    private enum ContextKeys: String, CodingKey {
        case compactor
    }

    private enum ObservabilityKeys: String, CodingKey {
        case logLevel, verboseRetentionDays
    }

    private enum StorageKeys: String, CodingKey {
        case retentionEnabled, maxDatabaseMb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let serverContainer = try container.nestedContainer(keyedBy: ServerKeys.self, forKey: .server)
        defaultModel = try serverContainer.decode(String.self, forKey: .defaultModel)
        defaultWorkspace = try serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        tailscaleIp = try serverContainer.decodeIfPresent(String.self, forKey: .tailscaleIp)

        let contextContainer = try container.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
        compaction = try contextContainer.decode(CompactionSettings.self, forKey: .compactor)

        let observabilityContainer = try container.nestedContainer(keyedBy: ObservabilityKeys.self, forKey: .observability)
        observabilityLogLevel = try observabilityContainer.decode(String.self, forKey: .logLevel)
        observabilityVerboseRetentionDays = try observabilityContainer.decode(UInt64.self, forKey: .verboseRetentionDays)

        let storageContainer = try container.nestedContainer(keyedBy: StorageKeys.self, forKey: .storage)
        storageRetentionEnabled = try storageContainer.decode(Bool.self, forKey: .retentionEnabled)
        storageMaxDatabaseMb = try storageContainer.decode(UInt64.self, forKey: .maxDatabaseMb)
    }

    struct CompactionSettings: Decodable {
        let preserveRecentCount: Int
        let triggerTokenThreshold: Double

        private enum CodingKeys: String, CodingKey {
            case preserveRecentCount, triggerTokenThreshold
        }

        init(preserveRecentCount: Int, triggerTokenThreshold: Double) {
            self.preserveRecentCount = preserveRecentCount
            self.triggerTokenThreshold = triggerTokenThreshold
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preserveRecentCount = try container.decode(Int.self, forKey: .preserveRecentCount)
            triggerTokenThreshold = try container.decode(Double.self, forKey: .triggerTokenThreshold)
        }
    }
}

struct ServerSettingsUpdate: Encodable {
    var server: ServerUpdate?
    var context: ContextUpdate?
    var observability: ObservabilityUpdate?
    var storage: StorageUpdate?

    struct ServerUpdate: Encodable {
        var defaultModel: String?
        var defaultWorkspace: String?
        var tailscaleIp: String?
    }

    struct ContextUpdate: Encodable {
        var compactor: CompactorUpdate?

        struct CompactorUpdate: Encodable {
            var preserveRecentCount: Int?
            var triggerTokenThreshold: Double?
        }
    }

    struct ObservabilityUpdate: Encodable {
        var logLevel: String?
        var verboseRetentionDays: UInt64?
    }

    struct StorageUpdate: Encodable {
        var retentionEnabled: Bool?
        var maxDatabaseMb: UInt64?
    }
}
