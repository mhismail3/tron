import Foundation

struct GitInspection: Equatable, Sendable {
    let isRepository: Bool
    let branch: String?
    let isDirty: Bool
}

struct GatewayLogRecord: Identifiable, Hashable, Sendable {
    let timestamp: String
    let level: String
    let message: String
    let event: String?
    let source: String?

    init(timestamp: String, level: String, message: String, event: String? = nil, source: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.event = event
        self.source = source
    }

    var id: String { "\(timestamp)-\(level)-\(event ?? "")-\(message)" }
}

struct GatewayProfileLogRecord: Hashable, Identifiable, Sendable {
    let profileID: String
    let profileLabel: String
    let record: GatewayLogRecord

    var id: String { "\(profileID):\(record.id)" }
}

typealias GatewayDiagnosticsRequest = @Sendable (String, JSONValue) async throws -> JSONValue

struct GatewayDiagnosticsService: Sendable {
    private let request: GatewayDiagnosticsRequest

    init(client: GatewayClient) {
        request = { method, params in
            try await client.requestValue(method, params)
        }
    }

    init(request: @escaping GatewayDiagnosticsRequest) {
        self.request = request
    }

    func inspectGit(path: String) async throws -> GitInspection {
        let value = try await request("git.inspect", .object(["path": .string(path)]))
        let object = value.objectValue
        return GitInspection(
            isRepository: object?["isRepository"]?.boolValue == true,
            branch: object?["branch"]?.stringValue,
            isDirty: object?["dirty"]?.boolValue ?? false
        )
    }

    func logs(limit: Int) async throws -> [GatewayLogRecord] {
        precondition(limit >= 0)
        let value = try await request("system.logs", .object(["limit": .number(Double(limit))]))
        let values = value.objectValue?["records"]?.arrayValue ?? []
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let timestamp = object["timestamp"]?.stringValue,
                  let level = object["level"]?.stringValue,
                  let message = object["message"]?.stringValue else { return nil }
            return GatewayLogRecord(
                timestamp: timestamp,
                level: level,
                message: message,
                event: object["event"]?.stringValue,
                source: object["source"]?.stringValue
            )
        }.reversed()
    }
}
