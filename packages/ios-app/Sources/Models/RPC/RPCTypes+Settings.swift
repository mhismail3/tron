import Foundation

// MARK: - Settings Methods

/// Server-authoritative settings decoded from `settings.get` RPC.
///
/// Every field uses `decodeIfPresent` with sensible defaults so that a missing
/// or newly-added field never crashes the entire decode. This is critical because
/// the Rust server's serde round-trip may drop unknown fields, and new server
/// versions may add fields that older iOS versions don't know about.
struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    let maxConcurrentSessions: Int
    let anthropicAccounts: [String]?
    let anthropicAccount: String?
    let compaction: CompactionSettings
    let memory: MemorySettings
    let rules: RulesSettings
    let tasks: TaskSettings
    let tools: ToolSettings

    private enum CodingKeys: String, CodingKey {
        case defaultModel, defaultWorkspace, maxConcurrentSessions
        case anthropicAccounts, anthropicAccount
        case compaction, memory, rules, tasks, tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = (try? container.decodeIfPresent(String.self, forKey: .defaultModel)) ?? "claude-sonnet-4-6"
        defaultWorkspace = try? container.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        maxConcurrentSessions = (try? container.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions)) ?? 10
        anthropicAccounts = try? container.decodeIfPresent([String].self, forKey: .anthropicAccounts)
        anthropicAccount = try? container.decodeIfPresent(String.self, forKey: .anthropicAccount)
        compaction = (try? container.decodeIfPresent(CompactionSettings.self, forKey: .compaction)) ?? .defaults
        memory = (try? container.decodeIfPresent(MemorySettings.self, forKey: .memory)) ?? .defaults
        rules = (try? container.decodeIfPresent(RulesSettings.self, forKey: .rules)) ?? .defaults
        tasks = (try? container.decodeIfPresent(TaskSettings.self, forKey: .tasks)) ?? .defaults
        tools = (try? container.decodeIfPresent(ToolSettings.self, forKey: .tools)) ?? .defaults
    }

    struct CompactionSettings: Decodable {
        let preserveRecentTurns: Int
        let forceAlways: Bool
        let triggerTokenThreshold: Double
        let alertZoneThreshold: Double
        let defaultTurnFallback: Int
        let alertTurnFallback: Int

        static let defaults = CompactionSettings(
            preserveRecentTurns: 5, forceAlways: false,
            triggerTokenThreshold: 0.70, alertZoneThreshold: 0.50,
            defaultTurnFallback: 8, alertTurnFallback: 5
        )

        private enum CodingKeys: String, CodingKey {
            case preserveRecentTurns, forceAlways, triggerTokenThreshold
            case alertZoneThreshold, defaultTurnFallback, alertTurnFallback
        }

        init(preserveRecentTurns: Int, forceAlways: Bool,
             triggerTokenThreshold: Double, alertZoneThreshold: Double,
             defaultTurnFallback: Int, alertTurnFallback: Int) {
            self.preserveRecentTurns = preserveRecentTurns
            self.forceAlways = forceAlways
            self.triggerTokenThreshold = triggerTokenThreshold
            self.alertZoneThreshold = alertZoneThreshold
            self.defaultTurnFallback = defaultTurnFallback
            self.alertTurnFallback = alertTurnFallback
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preserveRecentTurns = (try? container.decodeIfPresent(Int.self, forKey: .preserveRecentTurns)) ?? 5
            forceAlways = (try? container.decodeIfPresent(Bool.self, forKey: .forceAlways)) ?? false
            triggerTokenThreshold = (try? container.decodeIfPresent(Double.self, forKey: .triggerTokenThreshold)) ?? 0.70
            alertZoneThreshold = (try? container.decodeIfPresent(Double.self, forKey: .alertZoneThreshold)) ?? 0.50
            defaultTurnFallback = (try? container.decodeIfPresent(Int.self, forKey: .defaultTurnFallback)) ?? 8
            alertTurnFallback = (try? container.decodeIfPresent(Int.self, forKey: .alertTurnFallback)) ?? 5
        }
    }

    struct MemorySettings: Decodable {
        let ledger: LedgerSettings
        let autoInject: AutoInjectSettings

        static let defaults = MemorySettings(
            ledger: .defaults, autoInject: .defaults
        )

        private enum CodingKeys: String, CodingKey {
            case ledger, autoInject
        }

        init(ledger: LedgerSettings, autoInject: AutoInjectSettings) {
            self.ledger = ledger
            self.autoInject = autoInject
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ledger = (try? container.decodeIfPresent(LedgerSettings.self, forKey: .ledger)) ?? .defaults
            autoInject = (try? container.decodeIfPresent(AutoInjectSettings.self, forKey: .autoInject)) ?? .defaults
        }

        struct LedgerSettings: Decodable {
            let enabled: Bool
            static let defaults = LedgerSettings(enabled: true)
        }

        struct AutoInjectSettings: Decodable {
            let enabled: Bool
            let count: Int
            static let defaults = AutoInjectSettings(enabled: true, count: 5)

            private enum CodingKeys: String, CodingKey {
                case enabled, count
            }

            init(enabled: Bool, count: Int) {
                self.enabled = enabled
                self.count = count
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
                count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? 5
            }
        }
    }

    struct RulesSettings: Decodable {
        let discoverStandaloneFiles: Bool
        static let defaults = RulesSettings(discoverStandaloneFiles: true)

        private enum CodingKeys: String, CodingKey {
            case discoverStandaloneFiles
        }

        init(discoverStandaloneFiles: Bool) {
            self.discoverStandaloneFiles = discoverStandaloneFiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            discoverStandaloneFiles = (try? container.decodeIfPresent(Bool.self, forKey: .discoverStandaloneFiles)) ?? true
        }
    }

    struct TaskSettings: Decodable {
        let autoInject: AutoInjectSettings
        static let defaults = TaskSettings(autoInject: .defaults)

        private enum CodingKeys: String, CodingKey {
            case autoInject
        }

        init(autoInject: AutoInjectSettings) {
            self.autoInject = autoInject
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autoInject = (try? container.decodeIfPresent(AutoInjectSettings.self, forKey: .autoInject)) ?? .defaults
        }

        struct AutoInjectSettings: Decodable {
            let enabled: Bool
            static let defaults = AutoInjectSettings(enabled: false)
        }
    }

    struct ToolSettings: Decodable {
        let web: WebSettings
        static let defaults = ToolSettings(web: .defaults)

        private enum CodingKeys: String, CodingKey {
            case web
        }

        init(web: WebSettings) {
            self.web = web
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            web = (try? container.decodeIfPresent(WebSettings.self, forKey: .web)) ?? .defaults
        }

        struct WebSettings: Decodable {
            let fetch: FetchSettings
            let cache: CacheSettings
            static let defaults = WebSettings(fetch: .defaults, cache: .defaults)

            private enum CodingKeys: String, CodingKey {
                case fetch, cache
            }

            init(fetch: FetchSettings, cache: CacheSettings) {
                self.fetch = fetch
                self.cache = cache
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                fetch = (try? container.decodeIfPresent(FetchSettings.self, forKey: .fetch)) ?? .defaults
                cache = (try? container.decodeIfPresent(CacheSettings.self, forKey: .cache)) ?? .defaults
            }

            struct FetchSettings: Decodable {
                let timeoutMs: Int
                static let defaults = FetchSettings(timeoutMs: 30000)
            }

            struct CacheSettings: Decodable {
                let ttlMs: Int
                let maxEntries: Int
                static let defaults = CacheSettings(ttlMs: 900000, maxEntries: 100)
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
        var anthropicAccount: String?
    }

    struct ContextUpdate: Encodable {
        var compactor: CompactorUpdate?
        var memory: MemoryUpdate?
        var rules: RulesUpdate?
        var tasks: TasksUpdate?

        struct CompactorUpdate: Encodable {
            var preserveRecentCount: Int?
            var forceAlways: Bool?
            var triggerTokenThreshold: Double?
            var alertZoneThreshold: Double?
            var defaultTurnFallback: Int?
            var alertTurnFallback: Int?
        }

        struct MemoryUpdate: Encodable {
            var ledger: LedgerUpdate?
            var autoInject: AutoInjectUpdate?

            struct LedgerUpdate: Encodable {
                var enabled: Bool?
            }

            struct AutoInjectUpdate: Encodable {
                var enabled: Bool?
                var count: Int?
            }
        }

        struct RulesUpdate: Encodable {
            var discoverStandaloneFiles: Bool?
        }

        struct TasksUpdate: Encodable {
            var autoInject: AutoInjectUpdate?

            struct AutoInjectUpdate: Encodable {
                var enabled: Bool?
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
