import Foundation
import CryptoKit

struct SwiftAppDisplayReference: Codable, Sendable, Equatable {
    let sessionId: String
    let artifactId: String
}

struct SwiftAppInstallOffer: Codable, Sendable, Identifiable {
    let reference: SwiftAppDisplayReference
    let version: Int
    let id: String
    let appId: String
    let name: String
    let icon: String?
    let sourceSha256: String
    let sourceBytes: Int
    let feeds: [String]
}

struct SwiftAppInstallReview: Codable, Sendable {
    let offer: SwiftAppInstallOffer
    let installed: InstalledSwiftAppManifest?
    let reference: SwiftAppDisplayReference
    let source: String

    func admitted(source: String, reference: SwiftAppDisplayReference) throws -> Self {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        guard self.source == source, self.reference == reference, offer.reference == reference, offer.version == 1, offer.id.count == 64,
              offer.id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              offer.appId.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil,
              !offer.name.isEmpty, offer.name.utf8.count <= 80, (offer.icon?.utf8.count ?? 0) <= 80,
              source.utf8.count > 0, source.utf8.count <= 320_000,
              offer.sourceBytes == source.utf8.count, offer.sourceSha256 == digest,
              Set(offer.feeds).isSubset(of: ["ios-builds"]), Set(offer.feeds).count == offer.feeds.count,
              installed == nil || installed?.id == offer.appId else {
            throw InstalledSwiftAppFailure("The app offer does not match this exact displayed source. Prepare it again.")
        }
        return self
    }
}

struct SwiftAppPendingList: Decodable, Sendable { let offers: [SwiftAppInstallOffer] }

struct InstalledSwiftAppCatalog: Sendable {
    let apps: [InstalledSwiftAppManifest]
    let pending: [SwiftAppInstallOffer]
}

struct SwiftAppInstallCommand: Encodable, Sendable {
    let commandId: String
    let review: SwiftAppInstallReview
    let upgradeToV2: Bool

    enum CodingKeys: String, CodingKey {
        case commandId, sessionId, artifactId, offerId, expectedRevision, expectedSourceSha256, expectedInstanceId, upgradeToV2
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(commandId, forKey: .commandId)
        try values.encode(review.reference.sessionId, forKey: .sessionId)
        try values.encode(review.reference.artifactId, forKey: .artifactId)
        try values.encode(review.offer.id, forKey: .offerId)
        // Absence is an explicit reviewed precondition, not an omitted wildcard.
        try values.encode(review.installed?.revision, forKey: .expectedRevision)
        try values.encode(review.installed?.sourceSha256, forKey: .expectedSourceSha256)
        try values.encode(review.installed?.instanceId, forKey: .expectedInstanceId)
        try values.encode(upgradeToV2, forKey: .upgradeToV2)
    }
}

struct SwiftAppInstallResult: Codable, Sendable {
    let app: InstalledSwiftAppManifest
    let created: Bool
}
