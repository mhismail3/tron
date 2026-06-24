import Foundation

/// Atomic-write the `.onboarded` sentinel using the same
/// `tempfile + sync + rename` recipe as the Rust agent.
enum OnboardedSentinelWriter {
    enum Failure: Error, Equatable {
        case parentDirectoryMissing(URL)
        case writeFailed(String)
    }

    static func touch(at path: URL) throws {
        let parent = path.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let tmp = parent.appendingPathComponent(".onboarded.\(UUID().uuidString).tmp", isDirectory: false)
        // Include fractional seconds so repeated touches within the same
        // second produce distinct bodies. Rust's serde_json ISO timestamps
        // include millis too — keeps the format consistent across sides.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = formatter.string(from: Date()) + "\n"
        guard let data = body.data(using: .utf8) else {
            throw Failure.writeFailed("UTF-8 encoding failure")
        }
        do {
            try data.write(to: tmp, options: [.atomic])
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        do {
            // Use replaceItemAt for true atomic rename even when the
            // destination already exists.
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } catch {
            // Cleanup the tempfile on failure.
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
