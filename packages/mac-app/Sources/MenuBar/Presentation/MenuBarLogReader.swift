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

    static func fetchRecentLogs(tronHome: URL, limit: Int = defaultLimit) async -> Result<String, MenuBarLogReadError> {
        let logs = tronHome.appendingPathComponent("logs", isDirectory: true)
        var newestFirst: [RecentLogEntry] = []
        for index in 0..<segmentCount where newestFirst.count < limit {
            let url = logs.appendingPathComponent(index == 0 ? gatewayLogName : "\(gatewayLogName).\(index)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return .failure(.unreadableOutput("The Gateway log could not be read."))
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let entry = try? JSONDecoder().decode(RecentLogEntry.self, from: Data(line.utf8)) else { continue }
                newestFirst.append(entry)
                if newestFirst.count == limit { break }
            }
        }
        return .success(format(Array(newestFirst.reversed())))
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
