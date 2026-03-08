import Testing
import Foundation
@testable import TronMobile

@Suite("SharedContent")
struct SharedContentTests {

    // MARK: - Codable Round-Trip

    @Test("encode and decode with all fields")
    func encodeDecodeAllFields() throws {
        let original = SharedContent(
            text: "Hello world",
            url: "https://example.com",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedContent.self, from: data)

        #expect(decoded.text == "Hello world")
        #expect(decoded.url == "https://example.com")
        #expect(decoded.timestamp == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("encode and decode with text only")
    func encodeDecodeTextOnly() throws {
        let original = SharedContent(text: "Just text", url: nil, timestamp: Date())

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedContent.self, from: data)

        #expect(decoded.text == "Just text")
        #expect(decoded.url == nil)
    }

    @Test("encode and decode with URL only")
    func encodeDecodeURLOnly() throws {
        let original = SharedContent(text: nil, url: "https://example.com", timestamp: Date())

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedContent.self, from: data)

        #expect(decoded.text == nil)
        #expect(decoded.url == "https://example.com")
    }

    @Test("encode and decode with nil fields")
    func encodeDecodeNilFields() throws {
        let original = SharedContent(text: nil, url: nil, timestamp: Date())

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedContent.self, from: data)

        #expect(decoded.text == nil)
        #expect(decoded.url == nil)
    }
}

@Suite("SharedContent.buildSharePrompt")
struct SharedContentBuildPromptTests {

    @Test("URL-only share produces notes prompt with skill")
    func urlOnlyShare() {
        let content = SharedContent(text: nil, url: "https://example.com/article", timestamp: Date())
        let payload = content.buildSharePrompt()

        #expect(payload != nil)
        #expect(payload?.prompt == "Add this to your notes\n\nhttps://example.com/article")
        #expect(payload?.skillName == "obsidian")
    }

    @Test("URL + text share includes both in prompt")
    func urlWithTextShare() {
        let content = SharedContent(text: "Great article about Swift", url: "https://example.com", timestamp: Date())
        let payload = content.buildSharePrompt()

        #expect(payload != nil)
        #expect(payload?.prompt == "Add this to your notes\n\nhttps://example.com\n\nGreat article about Swift")
        #expect(payload?.skillName == "obsidian")
    }

    @Test("text-only share sends raw text without skill")
    func textOnlyShare() {
        let content = SharedContent(text: "Remember this for later", url: nil, timestamp: Date())
        let payload = content.buildSharePrompt()

        #expect(payload != nil)
        #expect(payload?.prompt == "Remember this for later")
        #expect(payload?.skillName == nil)
    }

    @Test("empty text-only share returns nil")
    func emptyTextShare() {
        let content = SharedContent(text: "", url: nil, timestamp: Date())
        #expect(content.buildSharePrompt() == nil)
    }

    @Test("nil text and nil URL returns nil")
    func nilBothShare() {
        let content = SharedContent(text: nil, url: nil, timestamp: Date())
        #expect(content.buildSharePrompt() == nil)
    }

    @Test("empty URL falls through to text-only")
    func emptyUrlWithText() {
        let content = SharedContent(text: "Just text", url: "", timestamp: Date())
        let payload = content.buildSharePrompt()

        #expect(payload != nil)
        #expect(payload?.prompt == "Just text")
        #expect(payload?.skillName == nil)
    }

    @Test("URL + empty text omits text portion")
    func urlWithEmptyText() {
        let content = SharedContent(text: "", url: "https://example.com", timestamp: Date())
        let payload = content.buildSharePrompt()

        #expect(payload?.prompt == "Add this to your notes\n\nhttps://example.com")
        #expect(payload?.skillName == "obsidian")
    }

    @Test("skill name constant is obsidian")
    func skillNameConstant() {
        #expect(SharedContent.urlShareSkillName == "obsidian")
    }
}

@Suite("PendingShareService")
struct PendingShareServiceTests {
    /// Use standard UserDefaults for testing (App Group suite requires entitlements)
    private let store = UserDefaults(suiteName: "com.tron.test.share.\(UUID().uuidString)")!

    @Test("save and load round-trip")
    func saveAndLoad() {
        let content = SharedContent(text: "Shared text", url: "https://example.com", timestamp: Date(timeIntervalSince1970: 1_000_000))

        PendingShareService.save(content, store: store)
        let loaded = PendingShareService.load(store: store)

        #expect(loaded != nil)
        #expect(loaded?.text == "Shared text")
        #expect(loaded?.url == "https://example.com")
        #expect(loaded?.timestamp == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("load returns nil when nothing saved")
    func loadReturnsNilWhenEmpty() {
        let emptyStore = UserDefaults(suiteName: "com.tron.test.share.empty.\(UUID().uuidString)")!
        let result = PendingShareService.load(store: emptyStore)
        #expect(result == nil)
    }

    @Test("clear removes pending share")
    func clearRemovesPendingShare() {
        let content = SharedContent(text: "To be cleared", url: nil, timestamp: Date())

        PendingShareService.save(content, store: store)
        #expect(PendingShareService.load(store: store) != nil)

        PendingShareService.clear(store: store)
        #expect(PendingShareService.load(store: store) == nil)
    }

    @Test("save overwrites previous content")
    func saveOverwritesPrevious() {
        let first = SharedContent(text: "First", url: nil, timestamp: Date())
        let second = SharedContent(text: "Second", url: "https://new.com", timestamp: Date())

        PendingShareService.save(first, store: store)
        PendingShareService.save(second, store: store)

        let loaded = PendingShareService.load(store: store)
        #expect(loaded?.text == "Second")
        #expect(loaded?.url == "https://new.com")
    }
}
