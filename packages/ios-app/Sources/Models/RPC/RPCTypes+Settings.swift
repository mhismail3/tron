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
    let integrations: IntegrationSettings

    private enum CodingKeys: String, CodingKey {
        case models, server, context, tools, integrations
    }

    private enum ModelsKeys: String, CodingKey {
        case `default`
    }

    private enum ServerKeys: String, CodingKey {
        case maxConcurrentSessions, defaultWorkspace, anthropicAccount, anthropicAccounts
    }

    private enum ContextKeys: String, CodingKey {
        case compactor, memory, rules, tasks
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
            memory = (try? contextContainer.decodeIfPresent(MemorySettings.self, forKey: .memory)) ?? .defaults
            rules = (try? contextContainer.decodeIfPresent(RulesSettings.self, forKey: .rules)) ?? .defaults
            tasks = (try? contextContainer.decodeIfPresent(TaskSettings.self, forKey: .tasks)) ?? .defaults
        } else {
            compaction = .defaults
            memory = .defaults
            rules = .defaults
            tasks = .defaults
        }

        tools = (try? container.decodeIfPresent(ToolSettings.self, forKey: .tools)) ?? .defaults
        integrations = (try? container.decodeIfPresent(IntegrationSettings.self, forKey: .integrations)) ?? .defaults
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
            let semanticInjection: Bool
            let recencyAnchorCount: Int
            static let defaults = AutoInjectSettings(
                enabled: true, count: 5, semanticInjection: true, recencyAnchorCount: 2
            )

            private enum CodingKeys: String, CodingKey {
                case enabled, count, semanticInjection, recencyAnchorCount
            }

            init(enabled: Bool, count: Int, semanticInjection: Bool, recencyAnchorCount: Int) {
                self.enabled = enabled
                self.count = count
                self.semanticInjection = semanticInjection
                self.recencyAnchorCount = recencyAnchorCount
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
                count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? 5
                semanticInjection = (try? container.decodeIfPresent(Bool.self, forKey: .semanticInjection)) ?? true
                recencyAnchorCount = (try? container.decodeIfPresent(Int.self, forKey: .recencyAnchorCount)) ?? 2
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

    struct IntegrationSettings: Decodable {
        let deviceContext: DeviceContextSettings
        let clipboard: ClipboardSettings
        let haptics: HapticsSettings
        let calendar: CalendarSettings
        let contacts: ContactsSettings
        let health: HealthSettings
        let location: LocationSettings

        static let defaults = IntegrationSettings(
            deviceContext: .defaults, clipboard: .defaults, haptics: .defaults,
            calendar: .defaults, contacts: .defaults, health: .defaults, location: .defaults
        )

        private enum CodingKeys: String, CodingKey {
            case deviceContext, clipboard, haptics, calendar, contacts, health, location
        }

        init(deviceContext: DeviceContextSettings, clipboard: ClipboardSettings,
             haptics: HapticsSettings, calendar: CalendarSettings,
             contacts: ContactsSettings, health: HealthSettings,
             location: LocationSettings) {
            self.deviceContext = deviceContext
            self.clipboard = clipboard
            self.haptics = haptics
            self.calendar = calendar
            self.contacts = contacts
            self.health = health
            self.location = location
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceContext = (try? container.decodeIfPresent(DeviceContextSettings.self, forKey: .deviceContext)) ?? .defaults
            clipboard = (try? container.decodeIfPresent(ClipboardSettings.self, forKey: .clipboard)) ?? .defaults
            haptics = (try? container.decodeIfPresent(HapticsSettings.self, forKey: .haptics)) ?? .defaults
            calendar = (try? container.decodeIfPresent(CalendarSettings.self, forKey: .calendar)) ?? .defaults
            contacts = (try? container.decodeIfPresent(ContactsSettings.self, forKey: .contacts)) ?? .defaults
            health = (try? container.decodeIfPresent(HealthSettings.self, forKey: .health)) ?? .defaults
            location = (try? container.decodeIfPresent(LocationSettings.self, forKey: .location)) ?? .defaults
        }

        struct DeviceContextSettings: Decodable {
            let enabled: Bool
            let battery: Bool
            let network: Bool
            let audioRoute: Bool
            let display: Bool
            let activity: Bool
            let calendarPreview: Bool

            static let defaults = DeviceContextSettings(
                enabled: false, battery: true, network: true, audioRoute: true,
                display: true, activity: true, calendarPreview: true
            )

            private enum CodingKeys: String, CodingKey {
                case enabled, battery, network, audioRoute, display, activity, calendarPreview
            }

            init(enabled: Bool, battery: Bool, network: Bool, audioRoute: Bool,
                 display: Bool, activity: Bool, calendarPreview: Bool) {
                self.enabled = enabled
                self.battery = battery
                self.network = network
                self.audioRoute = audioRoute
                self.display = display
                self.activity = activity
                self.calendarPreview = calendarPreview
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                battery = (try? container.decodeIfPresent(Bool.self, forKey: .battery)) ?? true
                network = (try? container.decodeIfPresent(Bool.self, forKey: .network)) ?? true
                audioRoute = (try? container.decodeIfPresent(Bool.self, forKey: .audioRoute)) ?? true
                display = (try? container.decodeIfPresent(Bool.self, forKey: .display)) ?? true
                activity = (try? container.decodeIfPresent(Bool.self, forKey: .activity)) ?? true
                calendarPreview = (try? container.decodeIfPresent(Bool.self, forKey: .calendarPreview)) ?? true
            }
        }

        struct ClipboardSettings: Decodable {
            let enabled: Bool
            static let defaults = ClipboardSettings(enabled: false)

            init(enabled: Bool) { self.enabled = enabled }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            }
            private enum CodingKeys: String, CodingKey { case enabled }
        }

        struct HapticsSettings: Decodable {
            let enabled: Bool
            let onTaskComplete: Bool
            let onError: Bool
            let onNotification: Bool

            static let defaults = HapticsSettings(
                enabled: false, onTaskComplete: true, onError: true, onNotification: true
            )

            private enum CodingKeys: String, CodingKey {
                case enabled, onTaskComplete, onError, onNotification
            }

            init(enabled: Bool, onTaskComplete: Bool, onError: Bool, onNotification: Bool) {
                self.enabled = enabled
                self.onTaskComplete = onTaskComplete
                self.onError = onError
                self.onNotification = onNotification
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                onTaskComplete = (try? container.decodeIfPresent(Bool.self, forKey: .onTaskComplete)) ?? true
                onError = (try? container.decodeIfPresent(Bool.self, forKey: .onError)) ?? true
                onNotification = (try? container.decodeIfPresent(Bool.self, forKey: .onNotification)) ?? true
            }
        }

        struct CalendarSettings: Decodable {
            let enabled: Bool
            let allowWrite: Bool

            static let defaults = CalendarSettings(enabled: false, allowWrite: false)

            private enum CodingKeys: String, CodingKey { case enabled, allowWrite }

            init(enabled: Bool, allowWrite: Bool) {
                self.enabled = enabled
                self.allowWrite = allowWrite
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                allowWrite = (try? container.decodeIfPresent(Bool.self, forKey: .allowWrite)) ?? false
            }
        }

        struct ContactsSettings: Decodable {
            let enabled: Bool
            static let defaults = ContactsSettings(enabled: false)

            init(enabled: Bool) { self.enabled = enabled }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            }
            private enum CodingKeys: String, CodingKey { case enabled }
        }

        struct HealthSettings: Decodable {
            let enabled: Bool
            let dataTypes: [String]

            static let defaults = HealthSettings(enabled: false, dataTypes: [])

            private enum CodingKeys: String, CodingKey { case enabled, dataTypes }

            init(enabled: Bool, dataTypes: [String]) {
                self.enabled = enabled
                self.dataTypes = dataTypes
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                dataTypes = (try? container.decodeIfPresent([String].self, forKey: .dataTypes)) ?? []
            }
        }

        struct LocationSettings: Decodable {
            let enabled: Bool
            let precision: String

            static let defaults = LocationSettings(enabled: false, precision: "city")

            private enum CodingKeys: String, CodingKey { case enabled, precision }

            init(enabled: Bool, precision: String) {
                self.enabled = enabled
                self.precision = precision
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                precision = (try? container.decodeIfPresent(String.self, forKey: .precision)) ?? "city"
            }
        }
    }
}

struct ServerSettingsUpdate: Encodable {
    var server: ServerUpdate?
    var context: ContextUpdate?
    var tools: ToolsUpdate?
    var integrations: IntegrationsUpdate?

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
            var maxPreservedRatio: Double?
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
                var semanticInjection: Bool?
                var recencyAnchorCount: Int?
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

    struct IntegrationsUpdate: Encodable {
        var deviceContext: DeviceContextUpdate?
        var clipboard: ClipboardUpdate?
        var haptics: HapticsUpdate?
        var calendar: CalendarUpdate?
        var contacts: ContactsUpdate?
        var health: HealthUpdate?
        var location: LocationUpdate?

        struct DeviceContextUpdate: Encodable {
            var enabled: Bool?
            var battery: Bool?
            var network: Bool?
            var audioRoute: Bool?
            var display: Bool?
            var activity: Bool?
            var calendarPreview: Bool?
        }

        struct ClipboardUpdate: Encodable {
            var enabled: Bool?
        }

        struct HapticsUpdate: Encodable {
            var enabled: Bool?
            var onTaskComplete: Bool?
            var onError: Bool?
            var onNotification: Bool?
        }

        struct CalendarUpdate: Encodable {
            var enabled: Bool?
            var allowWrite: Bool?
        }

        struct ContactsUpdate: Encodable {
            var enabled: Bool?
        }

        struct HealthUpdate: Encodable {
            var enabled: Bool?
            var dataTypes: [String]?
        }

        struct LocationUpdate: Encodable {
            var enabled: Bool?
            var precision: String?
        }
    }
}
