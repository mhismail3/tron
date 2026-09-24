import Foundation

/// Copy is a bounded diagnostic projection, never a transcript or credential
/// export. Profile labels are user-entered text, so use per-copy opaque aliases.
enum GatewayLogExport {
    static let maximumUploadBytes = 512 * 1024

    /// The Logs rows projected from `AppLog`. The export carries `AppLog`
    /// records directly, so it skips these rows instead of writing them twice.
    static let appLogProfileID = "ios-client"

    static func jsonLines(
        records: [GatewayProfileLogRecord], metadata: GatewayLogCaptureMetadata,
        appRecords: [AppLogRecord]
    ) -> String {
        let gatewayRecords = records.filter { $0.profileID != appLogProfileID }.prefix(1_000).map { item in
            let value = item.record
            // Retained phone diagnostics are keyed `<profile>:ios-client`.
            let process = item.profileID.hasSuffix(":\(appLogProfileID)") ? "ios" : "gateway"
            return AppLogRecord(
                timestamp: IOSClientDiagnosticBuffer.redactedMessage(value.timestamp),
                level: value.level, event: IOSClientDiagnosticBuffer.redactedMessage(value.event ?? "gateway.log"),
                source: IOSClientDiagnosticBuffer.redactedMessage(value.source ?? "gateway"),
                message: IOSClientDiagnosticBuffer.redactedMessage(value.message), process: process,
                requestID: value.requestID, durationMs: value.durationMs, outcome: value.outcome,
                code: value.code, profileID: nil, connectionID: nil, lifecycleGeneration: nil
            )
        }
        let metadata = metadata.withBounds(records: Array(records.prefix(1_000)))
        func owner(_ id: String) -> String {
            id.hasSuffix(":ios-client") ? String(id.dropLast(":ios-client".count)) : id
        }
        let owners = Set(records.prefix(1_000).map { owner($0.profileID) })
            .union(metadata.sourceStatuses.keys).union(metadata.gatewayIdentities.keys).sorted()
        let metadataLines = owners.enumerated().map { index, id in
            let alias = "source-\(index + 1)"
            let status = metadata.sourceStatuses[id] ?? "local-or-retained"
            let identity = IOSClientDiagnosticBuffer.redactedMessage(metadata.gatewayIdentities[id] ?? "unknown")
            return "\(alias).status=\(status) \(alias).gateway=\(identity)"
        }
        let appStarted = AppLogRecord(
            timestamp: GatewayTimestamp.preciseString(from: .now), level: "info",
            event: "diagnostics.exported", source: "lifecycle",
            message: ([
                "copiedAt=\(GatewayTimestamp.preciseString(from: .now))",
                "loadedAt=\(metadata.capturedAt)",
                "representedFrom=\(metadata.representedFrom ?? "unknown")",
                "representedThrough=\(metadata.representedThrough ?? "unknown")",
                "appBuild=\(IOSClientDiagnosticBuffer.redactedMessage(metadata.appBuildIdentity))",
                "appSourceRevision=\(safeToken(metadata.appSourceRevision) ?? "unknown")",
                "os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
            ] + metadataLines).joined(separator: " "),
            process: "ios", requestID: nil, durationMs: nil, outcome: nil, code: nil,
            profileID: nil, connectionID: nil, lifecycleGeneration: nil
        )
        let encoder = JSONEncoder()
        let localRecords = appRecords.map { value in
            AppLogRecord(
                timestamp: IOSClientDiagnosticBuffer.redactedMessage(value.timestamp), level: value.level,
                event: IOSClientDiagnosticBuffer.redactedMessage(value.event),
                source: IOSClientDiagnosticBuffer.redactedMessage(value.source),
                message: IOSClientDiagnosticBuffer.redactedMessage(value.message), process: "ios",
                requestID: value.requestID, durationMs: value.durationMs, outcome: value.outcome,
                code: value.code, profileID: value.profileID, connectionID: value.connectionID,
                lifecycleGeneration: value.lifecycleGeneration
            )
        }
        let lines = ([appStarted] + localRecords + gatewayRecords).prefix(1_000)
            .compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    static func text(
        records: [GatewayProfileLogRecord],
        metadata: GatewayLogCaptureMetadata,
        copiedAt: Date = .now
    ) -> String {
        let records = Array(records.prefix(1_000))
        let metadata = metadata.withBounds(records: records)
        func owner(_ id: String) -> String {
            id.hasSuffix(":ios-client") ? String(id.dropLast(":ios-client".count)) : id
        }
        let owners = Set(records.map { owner($0.profileID) })
            .union(metadata.sourceStatuses.keys).union(metadata.gatewayIdentities.keys).sorted()
        let aliases = Dictionary(uniqueKeysWithValues: owners.enumerated().map { ($0.element, "source-\($0.offset + 1)") })
        var lines = [
            "Tron diagnostics",
            "copiedAt=\(GatewayTimestamp.preciseString(from: copiedAt))",
            "loadedAt=\(metadata.capturedAt)",
            "representedFrom=\(metadata.representedFrom ?? "unknown")",
            "representedThrough=\(metadata.representedThrough ?? "unknown")",
            "appBuild=\(IOSClientDiagnosticBuffer.redactedMessage(metadata.appBuildIdentity)) appSourceRevision=\(safeToken(metadata.appSourceRevision) ?? "unknown")",
        ]
        for id in owners {
            lines.append("\(aliases[id]!) status=\(metadata.sourceStatuses[id] ?? "local-or-retained") gateway=\(IOSClientDiagnosticBuffer.redactedMessage(metadata.gatewayIdentities[id] ?? "unknown"))")
        }
        lines.append("")
        for value in records {
            let row = value.record
            let safe: (String) -> String = { IOSClientDiagnosticBuffer.redactedMessage($0) }
            let fields: [(String, String?)] = [("method", row.method), ("requestID", row.requestID), ("code", row.code), ("outcome", row.outcome), ("reason", row.reason)]
            var correlation = fields.compactMap { key, value in safeToken(value).map { "\(key)=\($0)" } }
            if let duration = row.durationMs, (0...86_400_000).contains(duration) { correlation.append("durationMs=\(duration)") }
            let suffix = correlation.isEmpty ? "" : " " + correlation.joined(separator: " ")
            lines.append("\(safe(row.timestamp)) [\(aliases[owner(value.profileID)]!)] [\(safe(row.level.uppercased()))] [\(safe(row.source ?? "unknown"))] [\(safe(row.event ?? "unknown"))] \(safe(row.message))\(suffix)")
        }
        return lines.joined(separator: "\n")
    }

    // Only opaque protocol identifiers cross this diagnostic projection. Never
    // serialize arbitrary request parameters or error details into exports.
    private static func safeToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 160,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
        return IOSClientDiagnosticBuffer.redactedMessage(value)
    }

    /// Keeps the export contract byte-bounded without splitting UTF-8 or
    /// removing its identifying header.
    static func uploadText(_ text: String) -> String {
        guard text.utf8.count > maximumUploadBytes else { return text }
        let marker = AppLogRecord(
            timestamp: GatewayTimestamp.preciseString(from: .now), level: "warning",
            event: "diagnostics.truncated", source: "lifecycle",
            message: "byteLimit=\(maximumUploadBytes)", process: "ios", requestID: nil,
            durationMs: nil, outcome: nil, code: nil, profileID: nil,
            connectionID: nil, lifecycleGeneration: nil
        )
        guard let markerData = try? JSONEncoder().encode(marker) else { return "" }
        let markerLine = markerData + Data([0x0A])
        let prefixLimit = maximumUploadBytes - markerLine.count
        var prefixLines: [String] = []
        var prefixBytes = 0
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  (try? JSONDecoder().decode(AppLogRecord.self, from: data)) != nil else { break }
            guard prefixBytes + data.count + 1 <= prefixLimit else { break }
            prefixLines.append(line)
            prefixBytes += data.count + 1
        }
        let prefix = prefixLines.isEmpty ? "" : prefixLines.joined(separator: "\n") + "\n"
        return prefix + String(decoding: markerLine, as: UTF8.self)
    }
}
