import Foundation

package struct AppLogUploadEpoch: Equatable, Sendable {
    package let id: String
    package let lines: [String]
}

package struct AppLogHeldCursor: Equatable, Sendable, Decodable {
    package let bootId: String?
    package let sequence: Int
}

package struct AppLogUploadBatch: Equatable, Sendable {
    package let bootId: String
    package let firstSequence: Int
    package let lines: [String]
    package let gapFrom: Int?
}

package enum AppLogUploadPlanner {
    package static let maximumBatchLines = 256
    package static let maximumBatchBytes = 256 * 1_024
    package static let maximumLineBytes = 16 * 1_024
    package static let gapReason = "local-rotation"

    package static func batches(epochs: [AppLogUploadEpoch], held: AppLogHeldCursor) -> [AppLogUploadBatch] {
        var start = 0
        var offset = 0
        var gapFrom: Int?
        if let bootId = held.bootId,
           let index = epochs.firstIndex(where: { $0.id == bootId }),
           held.sequence <= epochs[index].lines.count {
            start = index
            offset = held.sequence
        } else if held.bootId != nil {
            gapFrom = held.sequence
        }
        var batches: [AppLogUploadBatch] = []
        for (position, epoch) in epochs.enumerated() where position >= start {
            var cursor = position == start ? offset : 0
            while cursor < epoch.lines.count {
                var lines: [String] = []
                var bytes = 0
                while cursor + lines.count < epoch.lines.count, lines.count < maximumBatchLines {
                    let line = epoch.lines[cursor + lines.count]
                    let size = line.utf8.count
                    if !lines.isEmpty, bytes + size > maximumBatchBytes { break }
                    lines.append(line)
                    bytes += size
                }
                batches.append(AppLogUploadBatch(
                    bootId: epoch.id,
                    firstSequence: cursor + 1,
                    lines: lines,
                    gapFrom: batches.isEmpty ? gapFrom : nil
                ))
                cursor += lines.count
            }
        }
        return batches
    }
}
