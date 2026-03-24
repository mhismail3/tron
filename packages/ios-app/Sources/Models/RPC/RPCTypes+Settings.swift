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
    let rules: RulesSettings
    let tasks: TaskSettings
    let tools: ToolSettings
    let isolationMode: String
    let chatWorkingDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case models, server, context, tools, session
    }

    private enum SessionKeys: String, CodingKey {
        case isolation, chat
    }

    private enum ChatKeys: String, CodingKey {
        case workingDirectory
    }

    private enum IsolationKeys: String, CodingKey {
        case mode
    }

    private enum ModelsKeys: String, CodingKey {
        case `default`
    }

    private enum ServerKeys: String, CodingKey {
        case maxConcurrentSessions, defaultWorkspace, anthropicAccount, anthropicAccounts
    }

    private enum ContextKeys: String, CodingKey {
        case compactor, rules, tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // models.default
        if let modelsContainer = try? container.nestedContainer(keyedBy: ModelsKeys.self, forKey: .models) {
            defaultModel = (try? modelsContainer.decodeIfPresent(String.self, forKey: .default)) ?? "claude-sonnet-4-6"
        } else {
            defaultModel = "claude-sonnet-4-6"
        }

        // server.*
        if let serverContainer = try? container.nestedContainer(keyedBy: ServerKeys.self, forKey: .server) {
            maxConcurrentSessions = (try? serverContainer.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions)) ?? 10
            defaultWorkspace = try? serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
            anthropicAccounts = try? serverContainer.decodeIfPresent([String].self, forKey: .anthropicAccounts)
            anthropicAccount = try? serverContainer.decodeIfPresent(String.self, forKey: .anthropicAccount)
        } else {
            maxConcurrentSessions = 10
            defaultWorkspace = nil
            anthropicAccounts = nil
            anthropicAccount = nil
        }

        // context.*
        if let contextContainer = try? container.nestedContainer(keyedBy: ContextKeys.self, forKey: .context) {
            compaction = (try? contextContainer.decodeIfPresent(CompactionSettings.self, forKey: .compactor)) ?? .defaults
            rules = (try? contextContainer.decodeIfPresent(RulesSettings.self, forKey: .rules)) ?? .defaults
            tasks = (try? contextContainer.decodeIfPresent(TaskSettings.self, forKey: .tasks)) ?? .defaults
        } else {
            compaction = .defaults
            rules = .defaults
            tasks = .defaults
        }

        tools = (try? container.decodeIfPresent(ToolSettings.self, forKey: .tools)) ?? .defaults

        // session.isolation.mode + session.chat.workingDirectory
        if let sessionContainer = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session) {
            if let isoContainer = try? sessionContainer.nestedContainer(keyedBy: IsolationKeys.self, forKey: .isolation) {
                isolationMode = (try? isoContainer.decodeIfPresent(String.self, forKey: .mode)) ?? "always"
            } else {
                isolationMode = "always"
            }
            if let chatContainer = try? sessionContainer.nestedContainer(keyedBy: ChatKeys.self, forKey: .chat) {
                chatWorkingDirectory = try? chatContainer.decodeIfPresent(String.self, forKey: .workingDirectory)
            } else {
                chatWorkingDirectory = nil
            }
        } else {
            isolationMode = "always"
            chatWorkingDirectory = nil
        }
    }

    struct CompactionSettings: Decodable {
        let preserveRecentCount: Int
        let forceAlways: Bool
        let triggerTokenThreshold: Double
        let alertZoneThreshold: Double
        let defaultTurnFallback: Int
        let alertTurnFallback: Int
        let maxPreservedRatio: Double

        static let defaults = CompactionSettings(
            preserveRecentCount: 5, forceAlways: false,
            triggerTokenThreshold: 0.70, alertZoneThreshold: 0.50,
            defaultTurnFallback: 25, alertTurnFallback: 15,
            maxPreservedRatio: 0.20
        )

        private enum CodingKeys: String, CodingKey {
            case preserveRecentCount, forceAlways, triggerTokenThreshold
            case alertZoneThreshold, defaultTurnFallback, alertTurnFallback
            case maxPreservedRatio
        }

        init(preserveRecentCount: Int, forceAlways: Bool,
             triggerTokenThreshold: Double, alertZoneThreshold: Double,
             defaultTurnFallback: Int, alertTurnFallback: Int,
             maxPreservedRatio: Double = 0.20) {
            self.preserveRecentCount = preserveRecentCount
            self.forceAlways = forceAlways
            self.triggerTokenThreshold = triggerTokenThreshold
            self.alertZoneThreshold = alertZoneThreshold
            self.defaultTurnFallback = defaultTurnFallback
            self.alertTurnFallback = alertTurnFallback
            self.maxPreservedRatio = maxPreservedRatio
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preserveRecentCount = (try? container.decodeIfPresent(Int.self, forKey: .preserveRecentCount)) ?? 5
            forceAlways = (try? container.decodeIfPresent(Bool.self, forKey: .forceAlways)) ?? false
            triggerTokenThreshold = (try? container.decodeIfPresent(Double.self, forKey: .triggerTokenThreshold)) ?? 0.70
            alertZoneThreshold = (try? container.decodeIfPresent(Double.self, forKey: .alertZoneThreshold)) ?? 0.50
            defaultTurnFallback = (try? container.decodeIfPresent(Int.self, forKey: .defaultTurnFallback)) ?? 25
            alertTurnFallback = (try? container.decodeIfPresent(Int.self, forKey: .alertTurnFallback)) ?? 15
            maxPreservedRatio = (try? container.decodeIfPresent(Double.self, forKey: .maxPreservedRatio)) ?? 0.20
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
        let browser: BrowserSettings
        static let defaults = ToolSettings(web: .defaults, browser: .defaults)

        private enum CodingKeys: String, CodingKey {
            case web, browser
        }

        init(web: WebSettings, browser: BrowserSettings) {
            self.web = web
            self.browser = browser
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            web = (try? container.decodeIfPresent(WebSettings.self, forKey: .web)) ?? .defaults
            browser = (try? container.decodeIfPresent(BrowserSettings.self, forKey: .browser)) ?? .defaults
        }

        struct BrowserSettings: Decodable {
            let headed: Bool
            static let defaults = BrowserSettings(headed: false)

            init(headed: Bool) { self.headed = headed }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                headed = (try? container.decodeIfPresent(Bool.self, forKey: .headed)) ?? false
            }
            private enum CodingKeys: String, CodingKey { case headed }
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
    var session: SessionUpdate?

    struct ServerUpdate: Encodable {
        var defaultModel: String?
        var defaultWorkspace: String?
        var maxConcurrentSessions: Int?
        var anthropicAccount: String?
    }

    struct ContextUpdate: Encodable {
        var compactor: CompactorUpdate?
        var rules: RulesUpdate?
        var tasks: TasksUpdate?

        struct CompactorUpdate: Encodable {
            var preserveRecentCount: Int?
            var forceAlways: Bool?
            var triggerTokenThreshold: Double?
            var alertZoneThreshold: Double?
            var defaultTurnFallback: Int?
            var alertTurnFallback: Int?
            var maxPreservedRatio: Double?
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
        var browser: BrowserUpdate?

        struct BrowserUpdate: Encodable {
            var headed: Bool?
        }

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

    struct SessionUpdate: Encodable {
        var isolation: IsolationUpdate?
        var chat: ChatUpdate?

        struct IsolationUpdate: Encodable {
            var mode: String?
        }

        struct ChatUpdate: Encodable {
            var workingDirectory: String?
        }
    }

}
