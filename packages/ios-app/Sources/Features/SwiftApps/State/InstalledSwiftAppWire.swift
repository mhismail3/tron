import Foundation
import CryptoKit
import TronMobileCore

struct InstalledSwiftAppManifest: Codable, Sendable {
    let version: Int
    let id: String
    let name: String
    let icon: String?
    let revision: Int
    let sourceSha256: String
    let sourceBytes: Int
    let updatedAt: String
    let instanceId: String?
    let feeds: [String]?
}

struct InstalledSwiftAppEntry: Codable, Sendable {
    let key: String
    let value: JSONValue
}

struct InstalledSwiftAppSnapshot: Codable, Sendable {
    struct State: Codable, Sendable {
        let appId: String
        let revision: Int
        let entries: [InstalledSwiftAppEntry]
    }
    let app: InstalledSwiftAppManifest
    let source: String
    let state: State
    // Transport data stays below the interpreter; the runner decodes and admits
    // its declared feed before publishing an executable session.
    let feeds: [String: JSONValue]?

    func admitted(appID: String) throws -> Self {
        guard [1, 2].contains(app.version), app.id == appID, state.appId == appID,
              app.revision > 0, app.revision < 9_007_199_254_740_991,
              state.revision >= 0, state.revision < 9_007_199_254_740_991,
              !app.name.isEmpty, app.name.utf8.count <= 80,
              source.utf8.count == app.sourceBytes, app.sourceBytes > 0, app.sourceBytes <= 320_000,
              SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined() == app.sourceSha256,
              state.entries.count <= 1_000,
              Set(state.entries.map(\.key)).count == state.entries.count else {
            throw InstalledSwiftAppFailure("The installed app snapshot is invalid. Reopen it from its Gateway.")
        }
        if app.version == 1 {
            guard app.instanceId == nil, app.feeds == nil, feeds == nil else {
                throw InstalledSwiftAppFailure("The v1 app snapshot has undeclared capabilities.")
            }
        } else {
            guard let instance = app.instanceId, UUID(uuidString: instance) != nil,
                  let declared = app.feeds, Set(declared).isSubset(of: ["ios-builds"]), Set(declared).count == declared.count,
                  let feeds, Set(feeds.keys) == Set(declared) else {
                throw InstalledSwiftAppFailure("The app's declared feed snapshot is invalid.")
            }
            for feed in feeds.values {
                guard try JSONEncoder.gateway.encode(feed).count <= 256_000 else {
                    throw InstalledSwiftAppFailure("The app's feed snapshot exceeds its bounds.")
                }
            }
        }
        var bytes = 0
        for entry in state.entries {
            let encoded = try JSONEncoder.gateway.encode(entry.value)
            guard !entry.key.isEmpty, entry.key.utf8.count <= 256,
                  !entry.key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  encoded.count <= 256 * 1_024 else { throw InstalledSwiftAppFailure("The app's stored data exceeds its bounds.") }
            bytes += entry.key.utf8.count + encoded.count
        }
        guard bytes <= 512 * 1_024 else { throw InstalledSwiftAppFailure("The app's stored data exceeds 512 KB.") }
        return self
    }
}

struct InstalledSwiftAppCommit: Codable, Sendable {
    let commandId: String
    let appId: String
    let expectedRevision: Int
    let expectedSourceRevision: Int
    let expectedInstanceId: String?
    let set: [InstalledSwiftAppEntry]
}

struct InstalledSwiftAppAcknowledgement: Codable, Sendable {
    let appId: String
    let revision: Int
}

struct InstalledSwiftAppList: Codable, Sendable { let apps: [InstalledSwiftAppManifest] }
struct InstalledSwiftAppRenamed: Codable, Sendable { let app: InstalledSwiftAppManifest }
struct InstalledSwiftAppStateRevision: Codable, Sendable { let revision: Int }

struct InstalledSwiftAppFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
