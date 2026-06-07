import Foundation

// MARK: - Settings Methods

/// Server-authoritative settings decoded from `settings::get`.
///
/// This mirrors the primitive server settings surface. Deleted product planes
/// such as hooks, rules, memory retainers, plugin sources, git workflow policy,
/// and approval prompts are intentionally absent.
struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    let tailscaleIp: String?

    let compaction: CompactionSettings
    let queueDrainMode: String

    let observabilityLogLevel: String
    let observabilityVerboseRetentionDays: UInt64
    let storageRetentionEnabled: Bool
    let storageMaxDatabaseMb: UInt64

    private enum CodingKeys: String, CodingKey {
        case server, context, session, observability, storage
    }

    private enum ServerKeys: String, CodingKey {
        case defaultModel, defaultWorkspace, tailscaleIp
    }

    private enum ContextKeys: String, CodingKey {
        case compactor
    }

    private enum SessionKeys: String, CodingKey {
        case queueDrainMode
    }

    private enum ObservabilityKeys: String, CodingKey {
        case logLevel, verboseRetentionDays
    }

    private enum StorageKeys: String, CodingKey {
        case retentionEnabled, maxDatabaseMb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let serverContainer = try? container.nestedContainer(keyedBy: ServerKeys.self, forKey: .server) {
            defaultModel = (try? serverContainer.decodeIfPresent(String.self, forKey: .defaultModel)) ?? "claude-sonnet-4-6"
            defaultWorkspace = try? serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
            tailscaleIp = try? serverContainer.decodeIfPresent(String.self, forKey: .tailscaleIp)
        } else {
            defaultModel = "claude-sonnet-4-6"
            defaultWorkspace = nil
            tailscaleIp = nil
        }

        if let contextContainer = try? container.nestedContainer(keyedBy: ContextKeys.self, forKey: .context) {
            compaction = (try? contextContainer.decodeIfPresent(CompactionSettings.self, forKey: .compactor)) ?? .defaults
        } else {
            compaction = .defaults
        }

        if let sessionContainer = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session) {
            queueDrainMode = (try? sessionContainer.decodeIfPresent(String.self, forKey: .queueDrainMode)) ?? "sequential"
        } else {
            queueDrainMode = "sequential"
        }

        if let observabilityContainer = try? container.nestedContainer(keyedBy: ObservabilityKeys.self, forKey: .observability) {
            observabilityLogLevel = (try? observabilityContainer.decodeIfPresent(String.self, forKey: .logLevel)) ?? "info"
            observabilityVerboseRetentionDays = (try? observabilityContainer.decodeIfPresent(UInt64.self, forKey: .verboseRetentionDays)) ?? 7
        } else {
            observabilityLogLevel = "info"
            observabilityVerboseRetentionDays = 7
        }

        if let storageContainer = try? container.nestedContainer(keyedBy: StorageKeys.self, forKey: .storage) {
            storageRetentionEnabled = (try? storageContainer.decodeIfPresent(Bool.self, forKey: .retentionEnabled)) ?? true
            storageMaxDatabaseMb = (try? storageContainer.decodeIfPresent(UInt64.self, forKey: .maxDatabaseMb)) ?? 512
        } else {
            storageRetentionEnabled = true
            storageMaxDatabaseMb = 512
        }
    }

    struct CompactionSettings: Decodable {
        let preserveRecentCount: Int
        let triggerTokenThreshold: Double

        static let defaults = CompactionSettings(
            preserveRecentCount: 5,
            triggerTokenThreshold: 0.70
        )

        private enum CodingKeys: String, CodingKey {
            case preserveRecentCount, triggerTokenThreshold
        }

        init(preserveRecentCount: Int, triggerTokenThreshold: Double) {
            self.preserveRecentCount = preserveRecentCount
            self.triggerTokenThreshold = triggerTokenThreshold
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preserveRecentCount = (try? container.decodeIfPresent(Int.self, forKey: .preserveRecentCount)) ?? 5
            triggerTokenThreshold = (try? container.decodeIfPresent(Double.self, forKey: .triggerTokenThreshold)) ?? 0.70
        }
    }
}

enum QueueDrainMode: String, Encodable {
    case sequential, batched

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

struct ServerSettingsUpdate: Encodable {
    var server: ServerUpdate?
    var context: ContextUpdate?
    var session: SessionUpdate?
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

    struct SessionUpdate: Encodable {
        var queueDrainMode: QueueDrainMode?
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
