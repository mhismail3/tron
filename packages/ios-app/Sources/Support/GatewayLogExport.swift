import Foundation

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
            "appBuild=\(IOSClientDiagnosticBuffer.redactedMessage(metadata.appBuildIdentity)) appSourceRevision=unknown",
        ]
        for id in owners {
            lines.append("\(aliases[id]!) status=\(metadata.sourceStatuses[id] ?? "local-or-retained") gateway=\(IOSClientDiagnosticBuffer.redactedMessage(metadata.gatewayIdentities[id] ?? "unknown"))")
        }
        lines.append("")
        for value in records {
            let row = value.record
            let safe: (String) -> String = { IOSClientDiagnosticBuffer.redactedMessage($0) }
            lines.append("\(safe(row.timestamp)) [\(aliases[owner(value.profileID)]!)] [\(safe(row.level.uppercased()))] [\(safe(row.source ?? "unknown"))] [\(safe(row.event ?? "unknown"))] \(safe(row.message))")
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the export contract byte-bounded without splitting UTF-8 or
    /// removing its identifying header.
    static func uploadText(_ text: String) -> String {
        guard text.utf8.count > maximumUploadBytes else { return text }
        let marker = "[diagnostic export truncated at 512 KiB]"
        let prefixLimit = maximumUploadBytes - marker.utf8.count - 1
        let prefix = String(decoding: text.utf8.prefix(prefixLimit), as: UTF8.self)
        return "\(prefix)\n\(marker)"
    }
}
