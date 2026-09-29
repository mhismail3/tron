import Foundation
import Testing
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes these cover, written before the implementation: a cached page
/// from one Gateway is presented for another; the cache grows without bound as
/// filters are visited; a corrupt or truncated document is presented as a page;
/// a retired Gateway leaves its library page behind.
@Suite("Library first-page cache")
struct KnowledgeLibraryPageCacheTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "KnowledgeLibraryCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func page(_ id: String, revision: Int = 3) throws -> KnowledgeLibraryCachedPage {
        let row = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(id: id, title: "Entry \(id)"))
        return KnowledgeLibraryCachedPage(rows: [row], nextCursor: "page-2", stateRevision: revision)
    }

    @Test("a page is never presented for a different Gateway profile")
    func profileIsolation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = KnowledgeLibraryPageCache(root: root)
        await cache.save(profileID: "gateway-a", filterID: "sources|saved", page: try page("a"))
        let stored = await cache.page(profileID: "gateway-a", filterID: "sources|saved")
        #expect(stored?.rows.first?.id == "a")
        #expect(stored?.nextCursor == "page-2")
        #expect(await cache.page(profileID: "gateway-b", filterID: "sources|saved") == nil)
        #expect(await cache.page(profileID: "gateway-a", filterID: "sources|archived") == nil)
    }

    @Test("only the newest filters are kept")
    func filterBound() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = KnowledgeLibraryPageCache(root: root)
        for index in 0...(KnowledgeLibraryCachePolicy.maximumFilterKeysPerProfile + 2) {
            await cache.save(profileID: "gateway", filterID: "filter-\(index)", page: try page("row-\(index)"))
        }
        var present = 0
        for index in 0...(KnowledgeLibraryCachePolicy.maximumFilterKeysPerProfile + 2) {
            if await cache.page(profileID: "gateway", filterID: "filter-\(index)") != nil { present += 1 }
        }
        #expect(present == KnowledgeLibraryCachePolicy.maximumFilterKeysPerProfile)
        // The newest filters survived; the oldest were dropped.
        #expect(await cache.page(profileID: "gateway", filterID: "filter-0") == nil)
        #expect(await cache.page(profileID: "gateway", filterID: "filter-\(KnowledgeLibraryCachePolicy.maximumFilterKeysPerProfile + 2)") != nil)
    }

    @Test("a corrupt or truncated document presents no page")
    func corruption() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = KnowledgeLibraryPageCache(root: root)
        await cache.save(profileID: "gateway", filterID: "sources", page: try page("a"))
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("{not json".utf8).write(to: file)
        #expect(await cache.page(profileID: "gateway", filterID: "sources") == nil)
        // The discarded document is gone rather than retried forever.
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("a profile's cached page is removed with the profile")
    func removal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = KnowledgeLibraryPageCache(root: root)
        await cache.save(profileID: "gateway", filterID: "sources", page: try page("a"))
        await cache.remove(profileID: "gateway")
        #expect(await cache.page(profileID: "gateway", filterID: "sources") == nil)
    }

    @Test("an over-budget page is not written at all")
    func byteBound() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = KnowledgeLibraryPageCache(root: root)
        let longTitle = String(repeating: "x", count: 8_000)
        let rows = try (0..<80).map { try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(id: "row-\($0)", title: longTitle)) }
        await cache.save(profileID: "gateway", filterID: "sources", page: KnowledgeLibraryCachedPage(rows: rows, nextCursor: nil, stateRevision: 1))
        #expect(await cache.page(profileID: "gateway", filterID: "sources") == nil)
    }
}
