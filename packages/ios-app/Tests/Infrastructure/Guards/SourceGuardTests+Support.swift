import Testing
import Foundation

extension SourceGuardTests {
    func iosAppRoot(filePath: String = #filePath) -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let sources = candidate.appendingPathComponent("Sources")
            let tests = candidate.appendingPathComponent("Tests")
            let project = candidate.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: sources.path)
                && FileManager.default.fileExists(atPath: tests.path)
                && FileManager.default.fileExists(atPath: project.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        preconditionFailure("Could not locate packages/ios-app from \(filePath)")
    }

    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func sourceLineCount(_ url: URL) throws -> Int {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    func swiftFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL else { return nil }
            guard url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    func isSourceGuardFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("SourceGuardTests")
    }
}
