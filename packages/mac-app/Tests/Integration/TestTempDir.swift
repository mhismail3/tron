import Foundation

/// Creates a throwaway directory under `NSTemporaryDirectory()` for an
/// integration test. The caller removes it with `cleanup` in a `defer`.
enum TestTempDir {
    static func make() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("tron-mac-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
