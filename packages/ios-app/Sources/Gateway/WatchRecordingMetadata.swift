import Foundation

/// The canonical translation from Watch custody metadata to Gateway v1 capture.
enum WatchRecordingMetadata {
    static func canonicalDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func captureMetadata(files: [WatchRecordingFiles], metadata: [String: Any]) throws -> [String: Any] {
        guard let firstFile = files.first else { throw URLError(.cannotParseResponse) }
        guard let first = try JSONSerialization.jsonObject(with: Data(contentsOf: firstFile.metadataURL)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        func date(_ key: String) throws -> String {
            guard let seconds = metadata[key] as? Double, seconds.isFinite else { throw URLError(.cannotParseResponse) }
            return canonicalDate(Date(timeIntervalSince1970: seconds))
        }
        let timeline: [[String: Any]] = try files.map { file in
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file.metadataURL)) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            return ["segment": file.number,
                    "startMonotonicMilliseconds": value["startedMonotonicMilliseconds"] as? Int64 ?? 0,
                    "durationMilliseconds": value["durationMilliseconds"] as? Int64 ?? 0,
                    "pauseBeforeMilliseconds": value["pauseBeforeMilliseconds"] as? Int64 ?? 0,
                    "frameCount": value["frameCount"] as? Int64 ?? 0,
                    "codec": value["codec"] as? String ?? "", "format": value["format"] as? String ?? ""]
        }
        return ["schemaVersion": 1,
                "source": ["appVersion": first["appVersion"] as? String ?? "unknown", "platform": "watchOS", "platformVersion": first["platformVersion"] as? String ?? "unknown"],
                "startedAt": try date("startedAt"), "stoppedAt": try date("stoppedAt"), "clockOffsetMilliseconds": 0,
                "stopReason": metadata["stopReason"] as? String == "user" ? "user" : "recovered-partial",
                "recoveryStatus": metadata["recoveryStatus"] as? String == "complete" ? "complete" : "interrupted", "timeline": timeline]
    }
}
