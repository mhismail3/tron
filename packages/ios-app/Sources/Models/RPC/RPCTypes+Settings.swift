import Foundation

// MARK: - Settings Methods

struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    let compaction: CompactionSettings

    struct CompactionSettings: Decodable {
        let preserveRecentTurns: Int
        let forceAlways: Bool
    }
}

struct ServerSettingsUpdate: Encodable {
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
            var forceAlways: Bool?
        }
    }
}
