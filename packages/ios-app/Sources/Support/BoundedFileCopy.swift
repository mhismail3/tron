import Foundation

enum BoundedFileCopyError: Error {
    case changedSize
}

enum BoundedFileCopy {
    static func copy(
        from source: URL,
        to destination: URL,
        expectedSize: Int
    ) async throws {
        let copyTask = Task.detached(priority: .userInitiated) {
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [
                    .posixPermissions: 0o600,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            ) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            do {
                var copied = 0
                while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    guard chunk.count <= expectedSize - copied else {
                        throw BoundedFileCopyError.changedSize
                    }
                    try output.write(contentsOf: chunk)
                    copied += chunk.count
                }
                guard copied == expectedSize else { throw BoundedFileCopyError.changedSize }
                try output.synchronize()
            } catch {
                try? input.close()
                try? output.close()
                throw error
            }
            try input.close()
            try output.close()
        }
        try await withTaskCancellationHandler {
            try await copyTask.value
        } onCancel: {
            copyTask.cancel()
        }
    }
}
