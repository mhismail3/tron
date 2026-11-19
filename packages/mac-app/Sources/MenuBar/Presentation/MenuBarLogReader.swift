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
            guard appendNewest(of: url, into: &newestFirst, limit: limit) else {
                return .failure(.unreadableOutput("The Gateway log could not be read."))
            }
        }
        return .success(format(Array(newestFirst.reversed())))
    }

    private static func appendNewest(of url: URL, into newestFirst: inout [RecentLogEntry], limit: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard var end = try? handle.seekToEnd() else { return false }
        let window = UInt64(tailBytesPerSegment)
        var carry = Data()
        while newestFirst.count < limit, end > 0 {
            let start = end > window ? end - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(end - start)) else { return false }
            var body = chunk + carry
            if start > 0 {
                guard let newline = body.firstIndex(of: 0x0A) else {
                    carry = body
                    end = start
                    continue
                }
                carry = Data(body[..<newline])
                body = Data(body[body.index(after: newline)...])
            } else {
                carry = Data()
            }
            for line in body.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                guard let entry = try? JSONDecoder().decode(RecentLogEntry.self, from: Data(line)) else { continue }
                newestFirst.append(entry)
                if newestFirst.count == limit { break }
            }
            end = start
        }
        return true
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
