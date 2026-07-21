import Foundation

// MARK: - Settings Methods

/// Server-authoritative settings decoded from `settings::get`.
///
/// The server returns its complete validated engine settings. This DTO intentionally
/// admits only the mobile product-settings projection, ignores unrelated
/// provider/runtime/TUI keys, and decodes every admitted field strictly.
struct ServerSettings: Decodable {
    let autonomousWorkers: Bool
    let defaultModel: String
    let defaultWorkspace: String?
    let tailscaleIp: String?

    let compaction: CompactionSettings

    private enum CodingKeys: String, CodingKey {
        case autonomousWorkers, server, context
    }

    private enum ServerKeys: String, CodingKey {
        case defaultModel, defaultWorkspace, tailscaleIp
    }

    private enum ContextKeys: String, CodingKey {
        case compactor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        autonomousWorkers = try container.decode(Bool.self, forKey: .autonomousWorkers)

        let serverContainer = try container.nestedContainer(keyedBy: ServerKeys.self, forKey: .server)
        defaultModel = try serverContainer.decode(String.self, forKey: .defaultModel)
        defaultWorkspace = try serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        tailscaleIp = try serverContainer.decodeIfPresent(String.self, forKey: .tailscaleIp)
        let contextContainer = try container.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
        compaction = try contextContainer.decode(CompactionSettings.self, forKey: .compactor)
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
    var autonomousWorkers: Bool?
    var server: ServerUpdate?
    var context: ContextUpdate?

    struct ServerUpdate: Encodable {
        var defaultModel: String?
        var defaultWorkspace: String?
    }

    struct ContextUpdate: Encodable {
        var compactor: CompactorUpdate?

        struct CompactorUpdate: Encodable {
            var preserveRecentCount: Int?
            var triggerTokenThreshold: Double?
        }
    }
}
