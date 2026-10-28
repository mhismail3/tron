import Foundation

/// Immutable, read-only input from the installed app's declared Gateway feed.
/// Not program globals, persisted state, network access or a refresh cache.
package struct SwiftAppIOSBuildsFeed: Codable, Sendable {
    package let status: String
    package let builds: [SwiftAppIOSBuildRecord]
    package let message: String?

    package func admitted() throws -> Self {
        guard ["ready", "empty", "unavailable"].contains(status), builds.count <= 20,
              (status == "ready") == !builds.isEmpty,
              (message?.utf8.count ?? 0) <= 512,
              Set(builds.map(\.id)).count == builds.count,
              try JSONEncoder().encode(self).count <= 256_000 else {
            throw SwiftAppRuntimeError("The ios-builds feed exceeds its declared bounds")
        }
        for build in builds { try build.admit() }
        return self
    }

    var value: SwiftAppValue {
        .record(SwiftAppRecord(typeName: "IOSBuildsFeed", keys: ["status", "message", "builds"], fields: [
            "status": .string(status), "message": .string(message ?? ""),
            "builds": .array(builds.map(\.value))
        ]))
    }
}

package struct SwiftAppIOSBuildRecord: Codable, Sendable {
    package let id: String
    package let title: String
    package let notes: String
    package let commit: String
    package let branch: String
    package let mode: String
    package let time: String
    package let sha256: String
    package let bytes: Int
    package let bundle_id: String
    package let manifestURL: String
    package let installURL: String

    func admit() throws {
        guard id.range(of: #"^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}-[a-f0-9]{7,9}$"#, options: .regularExpression) != nil,
              !title.isEmpty, title.utf8.count <= 256, notes.utf8.count <= 4_096,
              !branch.isEmpty, branch.utf8.count <= 256, time.utf8.count <= 64,
              ["optimized", "fast-debug"].contains(mode),
              commit.range(of: #"^[a-f0-9]{7,64}$"#, options: .regularExpression) != nil,
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              bytes > 0, bytes <= 10 * 1_024 * 1_024 * 1_024,
              !bundle_id.isEmpty, bundle_id.utf8.count <= 256,
              let manifest = URLComponents(string: manifestURL), manifest.scheme == "https",
              manifest.path == "/builds/\(id)/manifest.plist", manifest.query == nil, manifest.fragment == nil,
              manifest.user == nil, manifest.password == nil, let host = manifest.host else {
            throw SwiftAppRuntimeError("The ios-builds feed contains an invalid build")
        }
        _ = try SwiftAppLinkPolicy(host: host, manifestURLs: [manifestURL]).admit(installURL)
    }

    var value: SwiftAppValue {
        let fields: [String: SwiftAppValue] = ["id": .string(id), "title": .string(title), "notes": .string(notes),
            "commit": .string(commit), "branch": .string(branch), "mode": .string(mode), "time": .string(time),
            "sha256": .string(sha256), "bytes": .int(bytes), "bundle_id": .string(bundle_id),
            "manifestURL": .string(manifestURL), "installURL": .string(installURL)]
        return .record(SwiftAppRecord(typeName: "IOSBuildRecord", keys: fields.keys.sorted(), fields: fields))
    }
}
