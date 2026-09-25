import Foundation

/// Atomic-write the `.onboarded` sentinel using the same
/// `tempfile + sync + rename` recipe used by gateway-owned state.
enum OnboardedSentinelWriter {
    enum Failure: Error, Equatable {
        case parentDirectoryMissing(URL)
        case writeFailed(String)
    }

    static func touch(at path: URL) throws {
        // Include fractional seconds so repeated touches within the same
        // second produce distinct bodies.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = formatter.string(from: Date()) + "\n"
        guard let data = body.data(using: .utf8) else {
            throw Failure.writeFailed("UTF-8 encoding failure")
        }
        do {
            try AtomicFileWriter.write(data, to: path)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
