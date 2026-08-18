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
        store.save(content)
        #expect(store.load() == content)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("corrupt pending data is ignored without inventing content")
    func corruptStore() {
        let suite = "SharedContentTests.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([0xFF]), forKey: "pendingShare")

        #expect(UserDefaultsPendingShareStore(defaults: defaults).load() == nil)
    }
}
