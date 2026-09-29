import CryptoKit
import Foundation
import TronMobileCore

/// The Library's bounded first-page cache. It keeps the page the Gateway last
/// admitted per profile and filter, so returning to the tab (or switching back
/// to a filter) shows content instead of a spinner. It is a projection, never an
/// authority: the Gateway's next page replaces it, and it is never presented for
/// a different Gateway profile.
struct KnowledgeLibraryCachedPage: Codable, Hashable, Sendable {
    let rows: [KnowledgeSourceRow]
    let nextCursor: String?
    let stateRevision: Int
}

enum KnowledgeLibraryCachePolicy {
    static let version = 1
    /// A handful of filters per Gateway; the Library's picker has few states and
    /// only the first page of each is worth keeping.
    static let maximumFilterKeysPerProfile = 8
    static let maximumEncodedBytes = 512 * 1_024
}

actor KnowledgeLibraryPageCache {
    private struct Entry: Codable {
        let filterID: String
        let savedAt: Double
        let rows: [KnowledgeSourceRow]
        let nextCursor: String?
        let stateRevision: Int
    }

    private struct Document: Codable {
        let version: Int
        let profileID: String
        let pages: [Entry]
    }

    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "KnowledgeLibrary", directoryHint: .isDirectory)
    }

    func page(profileID: String, filterID: String) -> KnowledgeLibraryCachedPage? {
        guard let document = read(profileID: profileID) else { return nil }
        guard let entry = document.pages.first(where: { $0.filterID == filterID }) else { return nil }
        return KnowledgeLibraryCachedPage(rows: entry.rows, nextCursor: entry.nextCursor, stateRevision: entry.stateRevision)
    }

    /// Records the accepted first page for one filter.
    func save(profileID: String, filterID: String, page: KnowledgeLibraryCachedPage) {
        var pages = read(profileID: profileID)?.pages ?? []
        pages.removeAll { $0.filterID == filterID }
        pages.append(Entry(filterID: filterID, savedAt: Date().timeIntervalSince1970, rows: page.rows, nextCursor: page.nextCursor, stateRevision: page.stateRevision))
        // Newest first, so the tail is what an over-budget document drops.
        pages.sort { $0.savedAt > $1.savedAt }
        pages = Array(pages.prefix(KnowledgeLibraryCachePolicy.maximumFilterKeysPerProfile))
        write(profileID: profileID, pages: pages)
    }

    func remove(profileID: String) {
        try? FileManager.default.removeItem(at: url(for: profileID))
        try? FileManager.default.removeItem(at: url(for: profileID).appendingPathExtension("tmp"))
    }

    private func url(for profileID: String) -> URL {
        let digest = KnowledgeCacheDigest.hex(profileID)
        return root.appending(path: "library-\(digest).json", directoryHint: .notDirectory)
    }

    private func read(profileID: String) -> Document? {
        let source = url(for: profileID)
        do {
            let data = try Data(contentsOf: source)
            guard data.count <= KnowledgeLibraryCachePolicy.maximumEncodedBytes else {
                try? FileManager.default.removeItem(at: source)
                return nil
            }
            let document = try JSONDecoder.gateway.decode(Document.self, from: data)
            guard document.version == KnowledgeLibraryCachePolicy.version, document.profileID == profileID else {
                try? FileManager.default.removeItem(at: source)
                return nil
            }
            return document
        } catch {
            try? FileManager.default.removeItem(at: source)
            return nil
        }
    }

    private func write(profileID: String, pages: [Entry]) {
        var admitted = pages
        func encoded(_ value: [Entry]) -> Data? {
            try? JSONEncoder.gateway.encode(Document(version: KnowledgeLibraryCachePolicy.version, profileID: profileID, pages: value))
        }
        // Enforce the byte bound by dropping the oldest filters rather than
        // writing a document no reader will admit.
        while !admitted.isEmpty {
            guard let data = encoded(admitted), data.count <= KnowledgeLibraryCachePolicy.maximumEncodedBytes else {
                admitted.removeLast()
                continue
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: url(for: profileID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // A disposable projection: a failed write leaves the previous
                // page in place and the next accepted page replaces it.
            }
            return
        }
        remove(profileID: profileID)
    }
}

enum KnowledgeCacheDigest {
    static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
