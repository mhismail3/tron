import Foundation

/// Additive provider account-usage capability. This is intentionally separate
/// from session context usage and from any local credential projection.
enum ProviderUsageCapability {
    static let name = "provider-usage.v1"
    static let maximumSnapshots = 16
    static let maximumWindows = 16
    static let maximumBalances = 4
    static let maximumStringBytes = 2_048

    static func invalid(_ reason: String = "The Gateway returned invalid provider usage.") -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: reason))
    }
}

struct ProviderUsageRequest: Codable, Hashable, Sendable {
    let sessionId: String?
    let providerId: String?

    init(sessionId: String? = nil, providerId: String? = nil) {
        self.sessionId = sessionId
        self.providerId = providerId
    }
}

enum ProviderUsageStatus: String, Codable, Hashable, Sendable {
    case available
    case unsupported
    case unconfigured
    case authenticationRequired = "authentication_required"
    case rateLimited = "rate_limited"
    case unavailable
}

enum ProviderUsageScope: String, Codable, Hashable, Sendable {
    case account
    case key
}

struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    let usedPercent: Double?
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let unit: String?
    let resetsAt: String?
    let windowSeconds: Int?

    init(
        id: String, label: String, usedPercent: Double? = nil, used: Double? = nil,
        limit: Double? = nil, remaining: Double? = nil, unit: String? = nil,
        resetsAt: String? = nil, windowSeconds: Int? = nil
    ) {
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.used = used
        self.limit = limit; self.remaining = remaining; self.unit = unit
        self.resetsAt = resetsAt; self.windowSeconds = windowSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPercent, used, limit, remaining, unit, resetsAt, windowSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.string(c, .id, required: true)
        label = try Self.string(c, .label, required: true)
        usedPercent = try Self.number(c, .usedPercent)
        used = try Self.number(c, .used)
        limit = try Self.number(c, .limit)
        remaining = try Self.number(c, .remaining)
        unit = try Self.optionalString(c, .unit)
        resetsAt = try Self.timestamp(c, .resetsAt)
        windowSeconds = try c.decodeIfPresent(Int.self, forKey: .windowSeconds)
        guard usedPercent.map({ $0 >= 0 }) ?? true,
              used.map({ $0 >= 0 }) ?? true,
              limit.map({ $0 > 0 }) ?? true,
              remaining.map({ $0 >= 0 }) ?? true,
              windowSeconds.map({ $0 > 0 }) ?? true else {
            throw ProviderUsageCapability.invalid("A provider usage window contains an invalid number.")
        }
    }

    private static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, required: Bool) throws -> String {
        guard let value = try c.decodeIfPresent(String.self, forKey: key) else {
            if required { throw ProviderUsageCapability.invalid("A provider usage window is missing a string.") }
            return ""
        }
        guard value.utf8.count <= ProviderUsageCapability.maximumStringBytes,
              !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderUsageCapability.invalid("A provider usage window contains an invalid string.")
        }
        return value
    }

    private static func optionalString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
        guard let value = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.utf8.count <= ProviderUsageCapability.maximumStringBytes else {
            throw ProviderUsageCapability.invalid("A provider usage window contains an oversized string.")
        }
        return value
    }

    private static func number<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Double? {
        guard let value = try c.decodeIfPresent(Double.self, forKey: key) else { return nil }
        guard value.isFinite else { throw ProviderUsageCapability.invalid("A provider usage window contains a non-finite number.") }
        return value
    }

    private static func timestamp<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
        guard let value = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.utf8.count <= ProviderUsageCapability.maximumStringBytes,
              GatewayTimestamp.parse(value) != nil else {
            throw ProviderUsageCapability.invalid("A provider usage timestamp is malformed.")
        }
        return value
    }
}

struct UsageBalance: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    let amount: Double
    let currency: String

    init(id: String, label: String, amount: Double, currency: String) {
        self.id = id; self.label = label; self.amount = amount; self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case id, label, amount, currency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        amount = try c.decode(Double.self, forKey: .amount)
        currency = try c.decode(String.self, forKey: .currency)
        guard !id.isEmpty, !label.isEmpty, !currency.isEmpty,
              id.utf8.count <= ProviderUsageCapability.maximumStringBytes,
              label.utf8.count <= ProviderUsageCapability.maximumStringBytes,
              currency.utf8.count <= 64, amount.isFinite else {
            throw ProviderUsageCapability.invalid("A provider usage balance is malformed.")
        }
    }
}

struct ProviderUsageSnapshot: Codable, Hashable, Sendable, Identifiable {
    let providerId: String
    var id: String { providerId }
    let status: ProviderUsageStatus
    let source: String?
    let scope: ProviderUsageScope?
    let updatedAt: String?
    let retryAt: String?
    let stale: Bool
    let message: String?
    let windows: [UsageWindow]
    let balances: [UsageBalance]

    init(
        providerId: String, status: ProviderUsageStatus, source: String? = nil,
        scope: ProviderUsageScope? = nil, updatedAt: String? = nil, retryAt: String? = nil,
        stale: Bool = false, message: String? = nil, windows: [UsageWindow] = [],
        balances: [UsageBalance] = []
    ) {
        self.providerId = providerId; self.status = status; self.source = source; self.scope = scope
        self.updatedAt = updatedAt; self.retryAt = retryAt; self.stale = stale; self.message = message
        self.windows = windows; self.balances = balances
    }

    private enum CodingKeys: String, CodingKey {
        case providerId, status, source, scope, updatedAt, retryAt, stale, message, windows, balances
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try c.decode(String.self, forKey: .providerId)
        status = try c.decode(ProviderUsageStatus.self, forKey: .status)
        source = try Self.optionalString(c, .source)
        scope = try c.decodeIfPresent(ProviderUsageScope.self, forKey: .scope)
        updatedAt = try Self.timestamp(c, .updatedAt)
        retryAt = try Self.timestamp(c, .retryAt)
        stale = try c.decode(Bool.self, forKey: .stale)
        message = try Self.optionalString(c, .message)
        windows = try c.decode([UsageWindow].self, forKey: .windows)
        balances = try c.decode([UsageBalance].self, forKey: .balances)
        guard !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              providerId.utf8.count <= ProviderUsageCapability.maximumStringBytes,
              windows.count <= ProviderUsageCapability.maximumWindows,
              balances.count <= ProviderUsageCapability.maximumBalances,
              Set(windows.map(\.id)).count == windows.count,
              Set(balances.map(\.id)).count == balances.count else {
            throw ProviderUsageCapability.invalid("A provider usage snapshot is oversized or duplicated.")
        }
    }

    private static func optionalString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
        guard let value = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.utf8.count <= ProviderUsageCapability.maximumStringBytes else {
            throw ProviderUsageCapability.invalid("A provider usage snapshot contains an oversized string.")
        }
        return value
    }

    private static func timestamp<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
        guard let value = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.utf8.count <= ProviderUsageCapability.maximumStringBytes,
              GatewayTimestamp.parse(value) != nil else {
            throw ProviderUsageCapability.invalid("A provider usage timestamp is malformed.")
        }
        return value
    }
}

struct ProviderUsageResponse: Codable, Sendable {
    let providers: [ProviderUsageSnapshot]

    init(providers: [ProviderUsageSnapshot]) {
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decode([ProviderUsageSnapshot].self, forKey: .providers)
        guard providers.count <= ProviderUsageCapability.maximumSnapshots,
              Set(providers.map(\.providerId)).count == providers.count else {
            throw ProviderUsageCapability.invalid("The provider usage response is oversized or duplicated.")
        }
    }

    private enum CodingKeys: String, CodingKey { case providers }
}

enum ProviderUsageOrdering {
    static func sorted(_ providers: [ProviderSummary]) -> [ProviderSummary] {
        providers.sorted {
            if $0.configured != $1.configured { return $0.configured && !$1.configured }
            let name = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return name == .orderedSame ? $0.id < $1.id : name == .orderedAscending
        }
    }
}
