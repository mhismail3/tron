import Foundation

// MARK: - Settings Methods

struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    let maxConcurrentSessions: Int
    let compaction: CompactionSettings
    let memory: MemorySettings
    let tools: ToolSettings

    struct CompactionSettings: Decodable {
        let preserveRecentTurns: Int
        let forceAlways: Bool
        let triggerTokenThreshold: Double
        let alertZoneThreshold: Double
        let defaultTurnFallback: Int
        let alertTurnFallback: Int
    }

    struct MemorySettings: Decodable {
        let autoInject: AutoInjectSettings

        struct AutoInjectSettings: Decodable {
            let enabled: Bool
            let count: Int
        }
    }

    struct ToolSettings: Decodable {
        let web: WebSettings

        struct WebSettings: Decodable {
            let fetch: FetchSettings
            let cache: CacheSettings

            struct FetchSettings: Decodable {
                let timeoutMs: Int
            }

            struct CacheSettings: Decodable {
                let ttlMs: Int
                let maxEntries: Int
            }
        }
    }
}

struct ServerSettingsUpdate: Encodable {
    var server: ServerUpdate?
    var context: ContextUpdate?
    var tools: ToolsUpdate?

    struct ServerUpdate: Encodable {
        var defaultModel: String?
        var defaultWorkspace: String?
        var maxConcurrentSessions: Int?
    }

    struct ContextUpdate: Encodable {
        var compactor: CompactorUpdate?
        var memory: MemoryUpdate?

        struct CompactorUpdate: Encodable {
            var preserveRecentCount: Int?
            var forceAlways: Bool?
            var triggerTokenThreshold: Double?
            var alertZoneThreshold: Double?
            var defaultTurnFallback: Int?
            var alertTurnFallback: Int?
        }

        struct MemoryUpdate: Encodable {
            var autoInject: AutoInjectUpdate?

            struct AutoInjectUpdate: Encodable {
                var enabled: Bool?
                var count: Int?
            }
        }
    }

    struct ToolsUpdate: Encodable {
        var web: WebUpdate?

        struct WebUpdate: Encodable {
            var fetch: FetchUpdate?
            var cache: CacheUpdate?

            struct FetchUpdate: Encodable {
                var timeoutMs: Int?
            }

            struct CacheUpdate: Encodable {
                var ttlMs: Int?
                var maxEntries: Int?
            }
        }
    }
}
