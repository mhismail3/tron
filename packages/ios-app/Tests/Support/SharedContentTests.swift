import Foundation
import Testing
@testable import TronMobile

@Suite("Shared-content pure boundaries")
struct SharedContentTests {
    @Test("fragment reduction preserves extension ordering semantics")
    func reduction() {
        let timestamp = Date(timeIntervalSince1970: 123)
        let content = SharedContentReducer.content(
            from: [
                .url("https://first.invalid"),
                .text("caption"),
                .url("https://second.invalid"),
            ],
            timestamp: timestamp
        )

        #expect(content == SharedContent(
            text: "caption\nhttps://second.invalid",
            url: "https://first.invalid",
            timestamp: timestamp
        ))
        #expect(SharedContentReducer.content(from: [], timestamp: timestamp) == nil)
    }

    @Test("share admission limits are explicit UTF-8 byte ratchets")
    func admissionLimits() {
        #expect(SharedContentAdmissionPolicy.maximumProviderCount == 32)
        #expect(SharedContentAdmissionPolicy.maximumFragmentBytes == 64 * 1_024)
        #expect(SharedContentAdmissionPolicy.maximumAggregateBytes == 128 * 1_024)
        #expect(SharedContentAdmissionPolicy.maximumPromptBytes == 192 * 1_024)
        #expect(SharedContentAdmissionPolicy.maximumStoredDocumentBytes == 256 * 1_024)

        let exactFragment = String(repeating: "a", count: SharedContentAdmissionPolicy.maximumFragmentBytes)
        #expect(SharedContentAdmissionPolicy.admits(.text(exactFragment)))
        #expect(!SharedContentAdmissionPolicy.admits(.text(exactFragment + "a")))
    }

    @Test("fragment count and aggregate bytes reject the whole share")
    func reductionBounds() {
        let exactCount = Array(
            repeating: SharedContentFragment.text("a"),
            count: SharedContentAdmissionPolicy.maximumProviderCount
        )
        #expect(SharedContentReducer.content(from: exactCount, timestamp: .distantPast) != nil)
        #expect(SharedContentReducer.content(from: exactCount + [.text("a")], timestamp: .distantPast) == nil)

        let withinAggregate = [
            SharedContentFragment.url(String(repeating: "a", count: 40 * 1_024)),
            .url(String(repeating: "b", count: 40 * 1_024)),
            .url(String(repeating: "c", count: 40 * 1_024)),
        ]
        #expect(SharedContentReducer.content(from: withinAggregate, timestamp: .distantPast) != nil)
        #expect(SharedContentReducer.content(
            from: withinAggregate + [.url(String(repeating: "d", count: 9 * 1_024))],
            timestamp: .distantPast
        ) == nil)
    }

    @Test("a later plain-text provider retains the current overwrite behavior")
    func laterText() {
        let content = SharedContentReducer.content(
            from: [
                .url("https://first.invalid"),
                .url("https://second.invalid"),
                .text("later caption"),
            ],
            timestamp: .distantPast
        )

        #expect(content?.url == "https://first.invalid")
        #expect(content?.text == "later caption")
    }

    @Test("share prompt keeps URL-before-text composition and rejects empty input")
    func prompt() {
        let content = SharedContent(
            text: "caption",
            url: "https://example.invalid",
            timestamp: .distantPast
        )
        let empty = SharedContent(text: " \n", url: nil, timestamp: .distantPast)

        #expect(content.buildSharePrompt()?.prompt == "https://example.invalid\n\ncaption")
        #expect(empty.buildSharePrompt() == nil)
    }

    @Test("pending share store round trips and clears one encoded value")
    func store() {
        let suite = "SharedContentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingShareStore(defaults: defaults)
        let content = SharedContent(
            text: "caption",
            url: "https://example.invalid",
            timestamp: Date(timeIntervalSince1970: 456)
        )

        #expect(store.load() == nil)
        #expect(store.save(content))
        #expect(store.load() == content)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("rejected pending shares do not replace an admitted value")
    func rejectedStoreWrite() {
        let suite = "SharedContentTests.rejected.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingShareStore(defaults: defaults)
        let admitted = SharedContent(text: "caption", url: nil, timestamp: .distantPast)
        let oversized = SharedContent(
            text: String(repeating: "x", count: SharedContentAdmissionPolicy.maximumAggregateBytes + 1),
            url: nil,
            timestamp: .distantPast
        )

        #expect(store.save(admitted))
        #expect(!store.save(oversized))
        #expect(store.load() == admitted)
    }

    @Test("encoded pending-share bytes are bounded before persistence")
    func encodedStoreBound() {
        let suite = "SharedContentTests.encoded.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingShareStore(defaults: defaults)
        let escaped = SharedContent(
            text: String(repeating: "\u{0001}", count: SharedContentAdmissionPolicy.maximumFragmentBytes),
            url: nil,
            timestamp: .distantPast
        )

        #expect(!store.save(escaped))
        #expect(store.load() == nil)
    }

    @Test("corrupt or oversized pending data is removed without inventing content")
    func corruptStore() {
        let suite = "SharedContentTests.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPendingShareStore(defaults: defaults)

        defaults.set(Data([0xFF]), forKey: "pendingShare")
        #expect(store.load() == nil)
        #expect(defaults.data(forKey: "pendingShare") == nil)

        defaults.set(Data(repeating: 0, count: SharedContentAdmissionPolicy.maximumStoredDocumentBytes + 1), forKey: "pendingShare")
        #expect(store.load() == nil)
        #expect(defaults.data(forKey: "pendingShare") == nil)
    }
}
