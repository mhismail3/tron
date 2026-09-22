import Foundation

enum GatewayLogShareAvailability: Equatable {
    case available
    case unavailable(String)

    static func resolve(hasVisibleLogs: Bool) -> Self {
        guard hasVisibleLogs else { return .unavailable("No logs are available to share yet.") }
        // A visible projection can always be written to a bounded local
        // artifact. Sharing never requires Gateway readiness or a remote
        // diagnostic export RPC.
        return .available
    }
}

/// Copy is a bounded diagnostic projection, never a transcript or credential
/// export. Profile labels are user-entered text, so use per-copy opaque aliases.
enum GatewayLogExport {
    static let maximumUploadBytes = 512 * 1024

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
        let marker = "[diagnostic export truncated at 512 KiB]"
        let prefixLimit = maximumUploadBytes - marker.utf8.count - 1
        // Decoding an arbitrary byte prefix can insert U+FFFD for a split
        // multibyte scalar, making the result exceed the byte bound. Trim the
        // decoded scalar boundary before appending the marker.
        var prefix = String(decoding: text.utf8.prefix(prefixLimit), as: UTF8.self)
        while prefix.utf8.count > prefixLimit { prefix.removeLast() }
        return "\(prefix)\n\(marker)"
    }
}
