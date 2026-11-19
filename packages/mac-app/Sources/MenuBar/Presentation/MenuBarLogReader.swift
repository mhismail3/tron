import Foundation

enum MenuBarLogReadError: Error, Equatable {
    case unreadableOutput(String)

    var message: String {
        switch self {
        case .unreadableOutput(let detail):
            return detail
        }
    }
}

enum MenuBarLogReader {
    static let defaultLimit = 200
    static let gatewayLogName = "gateway.jsonl"
    static let segmentCount = 8
    static let tailBytesPerSegment = 256 * 1_024

    static func fetchRecentLogs(tronHome: URL, limit: Int = defaultLimit) async -> Result<String, MenuBarLogReadError> {
        let logs = tronHome.appendingPathComponent("logs", isDirectory: true)
        var newestFirst: [RecentLogEntry] = []
        for index in 0..<segmentCount where newestFirst.count < limit {
            let url = logs.appendingPathComponent(index == 0 ? gatewayLogName : "\(gatewayLogName).\(index)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let lines = tailLines(of: url) else {
                return .failure(.unreadableOutput("The Gateway log could not be read."))
            }
            for line in lines.reversed() {
                guard let entry = try? JSONDecoder().decode(RecentLogEntry.self, from: line) else { continue }
                newestFirst.append(entry)
                if newestFirst.count == limit { break }
            }
        }
        return .success(format(Array(newestFirst.reversed())))
    }

    private static func tailLines(of url: URL) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let window = UInt64(tailBytesPerSegment)
        let start = end > window ? end - window : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var body = data[...]
        if start > 0 {
            guard let newline = body.firstIndex(of: 0x0A) else { return [] }
            body = body[body.index(after: newline)...]
        }
        return body.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    static func format(_ records: [RecentLogEntry]) -> String {
        records.map { entry in
            "[\(entry.timestamp)] \(entry.level.uppercased()) TRON: \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

struct RecentLogEntry: Decodable, Equatable {
    var timestamp: String
    var level: String
    var message: String
}
