import Foundation

/// Copy is a bounded diagnostic projection, never a transcript or credential
/// export. Profile labels are user-entered text, so use per-copy opaque aliases.
enum GatewayLogExport {
    /// One export carries at most this many JSON lines, the identifying header
    /// included.
    static let maximumExportLines = 1_000
    static let maximumUploadBytes = 512 * 1024

    /// The Logs rows projected from `AppLog`. The export carries `AppLog`
    /// records directly, so it skips these rows instead of writing them twice.
    static let appLogProfileID = "ios-client"

    static func jsonLines(
        records: [GatewayProfileLogRecord], metadata: GatewayLogCaptureMetadata,
        appRecords: [AppLogRecord]
    ) -> String {
        // The Logs surface hands `records` newest-first. Re-derive that order so
        // every bound below keeps the newest evidence whatever order a caller
        // supplies.
        let newestFirst = records.sorted { gatewayLogRecordIsNewer($0, than: $1) }
        let loadedComposition = Array(newestFirst.prefix(maximumExportLines))
        // Retained phone diagnostics are keyed `<profile>:ios-client`.
        func process(for profileID: String) -> String {
            profileID.hasSuffix(":\(appLogProfileID)") ? "ios" : "gateway"
        }
        func gatewayRecord(_ item: GatewayProfileLogRecord) -> AppLogRecord {
            let value = item.record
            return AppLogRecord(
                timestamp: IOSClientDiagnosticBuffer.redactedMessage(value.timestamp),
                level: value.level, event: IOSClientDiagnosticBuffer.redactedMessage(value.event ?? "gateway.log"),
                source: IOSClientDiagnosticBuffer.redactedMessage(value.source ?? "gateway"),
                message: IOSClientDiagnosticBuffer.redactedMessage(value.message), process: process(for: item.profileID),
                requestID: value.requestID, durationMs: value.durationMs, outcome: value.outcome,
                code: value.code, profileID: nil, connectionID: nil, lifecycleGeneration: nil
            )
        }
        func localRecord(_ value: AppLogRecord) -> AppLogRecord {
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
        let metadata = metadata.withBounds(records: loadedComposition)
        func owner(_ id: String) -> String {
            id.hasSuffix(":ios-client") ? String(id.dropLast(":ios-client".count)) : id
        }
        let owners = Set(loadedComposition.map { owner($0.profileID) })
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
        // The chat interaction trace is the incident evidence for chat
        // scroll/geometry bugs. Its producer bounds it to
        // `ChatInteractionTrace.maximumRecords`, and the export always carries
        // every retained record whatever else the payload weighs.
        let chatTrace = newestFirst.filter { $0.profileID == ChatInteractionTrace.diagnosticProfileID }
            .prefix(ChatInteractionTrace.maximumRecords)
        // The newest remaining records win the leftover slots. `AppLog` is
        // oldest-first, so it reverses into a newest-first candidate list; the
        // rows already projected from it are skipped instead of written twice.
        var candidates = appRecords.reversed().map(localRecord)
        candidates.append(contentsOf: newestFirst
            .filter { $0.profileID != appLogProfileID && $0.profileID != ChatInteractionTrace.diagnosticProfileID }
            .map(gatewayRecord))
        let newest = candidates.sorted { GatewayTimestamp.isNewer($0.timestamp, than: $1.timestamp) }
        let retained = Array(newest.prefix(max(0, maximumExportLines - 1 - chatTrace.count)))
            + chatTrace.map(gatewayRecord)
        // `isNewer` is a total order, so its inverse lists the retained evidence
        // oldest to newest behind the header.
        let encoder = JSONEncoder()
        let lines = ([appStarted] + retained.sorted { GatewayTimestamp.isNewer($1.timestamp, than: $0.timestamp) })
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
    /// removing its identifying header. The newest lines are kept: the oldest
    /// overflow is dropped ahead of the truncation marker.
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
        let lines = text.split(separator: "\n").map(String.init)
        guard let header = lines.first, let headerData = header.data(using: .utf8),
              (try? JSONDecoder().decode(AppLogRecord.self, from: headerData)) != nil else {
            return String(decoding: markerLine, as: UTF8.self)
        }
        var budget = maximumUploadBytes - markerLine.count - headerData.count - 1
        var body: [String] = []
        for rawLine in lines.dropFirst().reversed() {
            guard let data = rawLine.data(using: .utf8),
                  (try? JSONDecoder().decode(AppLogRecord.self, from: data)) != nil else { break }
            guard data.count + 1 <= budget else { break }
            body.append(rawLine)
            budget -= data.count + 1
        }
        let kept = ([header] + body.reversed()).joined(separator: "\n") + "\n"
        return kept + String(decoding: markerLine, as: UTF8.self)
    }
}
