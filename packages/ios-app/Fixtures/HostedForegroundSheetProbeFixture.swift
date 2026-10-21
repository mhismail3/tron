#if HOSTED_TEST
import Foundation

/// Opt-in investigation instrumentation, never compiled into the shipping app.
@MainActor enum ForegroundSheetProbe {
    private static var count = 0
    private static let enabled = ProcessInfo.processInfo.arguments.contains("-foreground-sheet-probe")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("foreground-sheet-probe.jsonl")

    static func record(_ event: String, _ identity: String) {
        guard enabled, count < 20_000 else { return }
        count += 1
        let value: [String: Any] = ["at": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "event": event, "identity": identity]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }
}
#endif
