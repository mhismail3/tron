import Foundation

// MARK: - Cron Job Types

/// A scheduled cron job.
struct CronJobDTO: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let enabled: Bool
    let schedule: CronScheduleDTO
    let payload: CronPayloadDTO
    let delivery: [CronDeliveryDTO]
    let overlapPolicy: String
    let misfirePolicy: String
    let maxRetries: Int
    let autoDisableAfter: Int
    let stuckTimeoutSecs: Int
    let tags: [String]
    let workspaceId: String?
    let createdAt: String
    let updatedAt: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CronJobDTO, rhs: CronJobDTO) -> Bool {
        lhs.id == rhs.id
    }
}

/// Runtime state for a cron job (next run, failure count, etc.).
struct CronRuntimeStateDTO: Codable {
    let jobId: String
    let nextRunAt: String?
    let lastRunAt: String?
    let consecutiveFailures: Int
    let runningSince: String?
}

/// A single execution record.
struct CronRunDTO: Codable, Identifiable {
    let id: String
    let jobId: String?
    let jobName: String
    let status: String
    let startedAt: String
    let completedAt: String?
    let durationMs: Int?
    let output: String?
    let outputTruncated: Bool
    let error: String?
    let exitCode: Int?
    let attempt: Int
    let sessionId: String?
    let deliveryStatus: String?
}

// MARK: - Schedule

enum CronScheduleDTO: Codable, Hashable {
    case cron(expression: String, timezone: String)
    case every(intervalSecs: Int, anchor: String?)
    case oneShot(at: String)

    enum CodingKeys: String, CodingKey {
        case type
        case expression, timezone
        case intervalSecs, anchor
        case at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "cron":
            let expr = try container.decode(String.self, forKey: .expression)
            let tz = try container.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
            self = .cron(expression: expr, timezone: tz)
        case "every":
            let secs = try container.decode(Int.self, forKey: .intervalSecs)
            let anchor = try container.decodeIfPresent(String.self, forKey: .anchor)
            self = .every(intervalSecs: secs, anchor: anchor)
        case "at":
            let at = try container.decode(String.self, forKey: .at)
            self = .oneShot(at: at)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown schedule type: \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cron(let expression, let timezone):
            try container.encode("cron", forKey: .type)
            try container.encode(expression, forKey: .expression)
            try container.encode(timezone, forKey: .timezone)
        case .every(let intervalSecs, let anchor):
            try container.encode("every", forKey: .type)
            try container.encode(intervalSecs, forKey: .intervalSecs)
            try container.encodeIfPresent(anchor, forKey: .anchor)
        case .oneShot(let at):
            try container.encode("at", forKey: .type)
            try container.encode(at, forKey: .at)
        }
    }

    /// Human-readable summary of the schedule.
    var summary: String {
        switch self {
        case .cron(let expression, let timezone):
            return Self.describeCron(expression, timezone: timezone)
        case .every(let intervalSecs, _):
            if intervalSecs >= 86400 {
                let days = intervalSecs / 86400
                return "Every \(days)d"
            } else if intervalSecs >= 3600 {
                let hours = intervalSecs / 3600
                return "Every \(hours)h"
            } else if intervalSecs >= 60 {
                let mins = intervalSecs / 60
                return "Every \(mins)m"
            }
            return "Every \(intervalSecs)s"
        case .oneShot(let at):
            return "Once at \(at)"
        }
    }

    /// Convert a 5-field cron expression + IANA timezone to human-readable text.
    private static func describeCron(_ expression: String, timezone: String) -> String {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return "\(expression) (\(timezone))" }

        let (min, hour, dom, mon, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        let tz = shortTimezone(timezone)
        let time = formatTime(hour: hour, minute: min)

        // "0 9 * * *" → "Daily at 9:00 AM (PT)"
        if dom == "*" && mon == "*" && dow == "*", let time {
            return "Daily at \(time) (\(tz))"
        }

        // "0 9 * * 1-5" or "0 9 * * MON-FRI" → "Weekdays at 9:00 AM (PT)"
        if dom == "*" && mon == "*" && isWeekdays(dow), let time {
            return "Weekdays at \(time) (\(tz))"
        }

        // "0 9 * * 0,6" or "0 9 * * SAT,SUN" → "Weekends at 9:00 AM (PT)"
        if dom == "*" && mon == "*" && isWeekends(dow), let time {
            return "Weekends at \(time) (\(tz))"
        }

        // "0 9 * * 1" → "Mon at 9:00 AM (PT)"
        if dom == "*" && mon == "*", let dayName = singleDayName(dow), let time {
            return "\(dayName) at \(time) (\(tz))"
        }

        // "0 9 1 * *" → "1st of each month at 9:00 AM (PT)"
        if mon == "*" && dow == "*", let dayNum = Int(dom), let time {
            return "\(ordinal(dayNum)) of each month at \(time) (\(tz))"
        }

        // Fallback
        return "\(expression) (\(tz))"
    }

    private static func formatTime(hour: String, minute: String) -> String? {
        guard let h = Int(hour), let m = Int(minute), (0...23).contains(h), (0...59).contains(m) else {
            return nil
        }
        let period = h < 12 ? "AM" : "PM"
        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return m == 0 ? "\(h12) \(period)" : "\(h12):\(String(format: "%02d", m)) \(period)"
    }

    private static func shortTimezone(_ iana: String) -> String {
        let map: [String: String] = [
            "America/New_York": "ET", "America/Chicago": "CT",
            "America/Denver": "MT", "America/Los_Angeles": "PT",
            "America/Phoenix": "MST", "Pacific/Honolulu": "HST",
            "America/Anchorage": "AKT", "Europe/London": "GMT",
            "Europe/Paris": "CET", "Europe/Berlin": "CET",
            "Asia/Tokyo": "JST", "Asia/Shanghai": "CST",
            "Asia/Kolkata": "IST", "Australia/Sydney": "AEST",
        ]
        return map[iana] ?? iana.components(separatedBy: "/").last ?? iana
    }

    private static func isWeekdays(_ dow: String) -> Bool {
        ["1-5", "MON-FRI", "mon-fri"].contains(dow)
    }

    private static func isWeekends(_ dow: String) -> Bool {
        let normalized = dow.uppercased().split(separator: ",").sorted()
        return normalized == ["0", "6"] || normalized == ["SAT", "SUN"] || normalized == ["6", "7"]
    }

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let dayAbbrevMap: [String: String] = [
        "SUN": "Sun", "MON": "Mon", "TUE": "Tue", "WED": "Wed",
        "THU": "Thu", "FRI": "Fri", "SAT": "Sat",
    ]

    private static func singleDayName(_ dow: String) -> String? {
        if let num = Int(dow), (0...6).contains(num) { return dayNames[num] }
        return dayAbbrevMap[dow.uppercased()]
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}

// MARK: - Payload

enum CronPayloadDTO: Codable, Hashable {
    case agentTurn(prompt: String, model: String?, workspaceId: String?, systemPrompt: String?)
    case shellCommand(command: String, workingDirectory: String?, timeoutSecs: Int?)
    case webhook(url: String, method: String?, headers: [String: String]?, body: String?, timeoutSecs: Int?)
    case systemEvent(sessionId: String, message: String)

    enum CodingKeys: String, CodingKey {
        case type
        case prompt, model, workspaceId, systemPrompt
        case command, workingDirectory, timeoutSecs
        case url, method, headers, body
        case sessionId, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "agentTurn":
            self = .agentTurn(
                prompt: try container.decode(String.self, forKey: .prompt),
                model: try container.decodeIfPresent(String.self, forKey: .model),
                workspaceId: try container.decodeIfPresent(String.self, forKey: .workspaceId),
                systemPrompt: try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            )
        case "shellCommand":
            self = .shellCommand(
                command: try container.decode(String.self, forKey: .command),
                workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
                timeoutSecs: try container.decodeIfPresent(Int.self, forKey: .timeoutSecs)
            )
        case "webhook":
            self = .webhook(
                url: try container.decode(String.self, forKey: .url),
                method: try container.decodeIfPresent(String.self, forKey: .method),
                headers: try container.decodeIfPresent([String: String].self, forKey: .headers),
                body: try container.decodeIfPresent(String.self, forKey: .body),
                timeoutSecs: try container.decodeIfPresent(Int.self, forKey: .timeoutSecs)
            )
        case "systemEvent":
            self = .systemEvent(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                message: try container.decode(String.self, forKey: .message)
            )
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown payload type: \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agentTurn(let prompt, let model, let workspaceId, let systemPrompt):
            try container.encode("agentTurn", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
            try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        case .shellCommand(let command, let workingDirectory, let timeoutSecs):
            try container.encode("shellCommand", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
            try container.encodeIfPresent(timeoutSecs, forKey: .timeoutSecs)
        case .webhook(let url, let method, let headers, let body, let timeoutSecs):
            try container.encode("webhook", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(method, forKey: .method)
            try container.encodeIfPresent(headers, forKey: .headers)
            try container.encodeIfPresent(body, forKey: .body)
            try container.encodeIfPresent(timeoutSecs, forKey: .timeoutSecs)
        case .systemEvent(let sessionId, let message):
            try container.encode("systemEvent", forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(message, forKey: .message)
        }
    }

    /// Human-readable type label.
    var typeLabel: String {
        switch self {
        case .agentTurn: return "Agent Turn"
        case .shellCommand: return "Shell Command"
        case .webhook: return "Webhook"
        case .systemEvent: return "System Event"
        }
    }

    /// Icon for the payload type.
    var icon: String {
        switch self {
        case .agentTurn: return "cpu"
        case .shellCommand: return "terminal"
        case .webhook: return "network"
        case .systemEvent: return "bolt.fill"
        }
    }
}

// MARK: - Delivery

enum CronDeliveryDTO: Codable, Hashable {
    case silent
    case webSocket
    case apns(title: String?)
    case webhook(url: String, headers: [String: String]?)

    enum CodingKeys: String, CodingKey {
        case type, title, url, headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "silent": self = .silent
        case "websocket": self = .webSocket
        case "apns":
            self = .apns(title: try container.decodeIfPresent(String.self, forKey: .title))
        case "webhook":
            self = .webhook(
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decodeIfPresent([String: String].self, forKey: .headers)
            )
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown delivery type: \(type)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .silent:
            try container.encode("silent", forKey: .type)
        case .webSocket:
            try container.encode("websocket", forKey: .type)
        case .apns(let title):
            try container.encode("apns", forKey: .type)
            try container.encodeIfPresent(title, forKey: .title)
        case .webhook(let url, let headers):
            try container.encode("webhook", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(headers, forKey: .headers)
        }
    }
}

// MARK: - RPC Params & Results

struct CronListParams: Encodable {
    let enabled: Bool?
    let tags: [String]?
    let workspaceId: String?
}

struct CronListResult: Decodable {
    let jobs: [CronJobDTO]
    let runtimeState: [CronRuntimeStateDTO]
}

struct CronGetParams: Encodable {
    let jobId: String
}

struct CronGetResult: Decodable {
    let job: CronJobDTO
    let runtimeState: CronRuntimeStateDTO?
    let recentRuns: [CronRunDTO]
}

struct CronCreateParams: Encodable {
    let job: CronCreateJobParams
}

struct CronCreateJobParams: Encodable {
    let name: String
    let description: String?
    let enabled: Bool?
    let schedule: CronScheduleDTO
    let payload: CronPayloadDTO
    let delivery: [CronDeliveryDTO]?
    let overlapPolicy: String?
    let misfirePolicy: String?
    let maxRetries: Int?
    let autoDisableAfter: Int?
    let tags: [String]?
    let workspaceId: String?
}

struct CronCreateResult: Decodable {
    let job: CronJobDTO
}

struct CronUpdateParams: Encodable {
    let jobId: String
    let name: String?
    let description: String?
    let enabled: Bool?
    let schedule: CronScheduleDTO?
    let payload: CronPayloadDTO?
    let delivery: [CronDeliveryDTO]?
    let overlapPolicy: String?
    let misfirePolicy: String?
    let maxRetries: Int?
    let autoDisableAfter: Int?
    let tags: [String]?
    let workspaceId: String?
}

struct CronUpdateResult: Decodable {
    let job: CronJobDTO
}

struct CronDeleteParams: Encodable {
    let jobId: String
}

struct CronDeleteResult: Decodable {
    let deleted: Bool
}

struct CronRunParams: Encodable {
    let jobId: String
}

struct CronRunResult: Decodable {
    let triggered: Bool
    let jobId: String
}

struct CronStatusResult: Decodable {
    let running: Bool
    let jobCount: Int
    let activeRuns: Int
    let nextWakeup: String?
    let executionLimit: Int
}

struct CronGetRunsParams: Encodable {
    let jobId: String
    let limit: Int?
    let offset: Int?
    let status: String?
}

struct CronGetRunsResult: Decodable {
    let runs: [CronRunDTO]
    let total: Int
}
