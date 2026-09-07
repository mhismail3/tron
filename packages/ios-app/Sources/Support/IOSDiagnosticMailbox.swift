import Foundation

/// Bounded handoff to the incident store. Producers never await disk or enqueue
/// one Task per record; a stalled writer retains the newest records by occurrence.
final class IOSDiagnosticMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(GatewayProfileLogRecord, Int)] = []
    private var bytes = 0
    private var writer: Task<Void, Never>?

    func enqueue(_ records: [GatewayProfileLogRecord], drain: @escaping @Sendable () async -> Void) {
        let entries = records.prefix(IOSClientDiagnosticStore.maximumRecords).reversed().compactMap { record -> (GatewayProfileLogRecord, Int)? in
            guard let size = try? JSONEncoder.gateway.encode(record).count,
                  size <= IOSClientDiagnosticStore.maximumBytes else { return nil }
            return (record, size)
        }
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: entries)
        pending.sort { gatewayLogRecordIsNewer($0.0, than: $1.0) }
        bytes = pending.reduce(0) { $0 + $1.1 }
        while pending.count > IOSClientDiagnosticStore.maximumRecords || bytes > IOSClientDiagnosticStore.maximumBytes {
            bytes -= pending.removeLast().1
        }
        if writer == nil { writer = Task { await drain() } }
    }

    func take() -> [GatewayProfileLogRecord]? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            writer = nil
            return nil
        }
        let batch = pending.map(\.0)
        pending.removeAll(keepingCapacity: true)
        bytes = 0
        return batch
    }

    func currentWriter() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return writer
    }
}
