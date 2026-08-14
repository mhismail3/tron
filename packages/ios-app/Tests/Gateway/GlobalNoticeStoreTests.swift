import Testing
@testable import TronMobile

@Suite("Bounded global notices")
struct GlobalNoticeStoreTests {
    @Test("count and UTF-8 storage remain bounded")
    func boundedStorage() {
        var store = GlobalNoticeStore()
        for index in 0..<(GlobalNoticeStore.maximumCount + 4) {
            store.post("notice-\(index)")
        }
        #expect(store.messages.count == GlobalNoticeStore.maximumCount)
        #expect(store.messages.first == "notice-4")

        store.post(String(repeating: "🟢", count: GlobalNoticeStore.maximumMessageBytes))
        #expect((store.latest?.utf8.count ?? 0) <= GlobalNoticeStore.maximumMessageBytes)

        var byteBounded = GlobalNoticeStore()
        for index in 0..<GlobalNoticeStore.maximumCount {
            byteBounded.post("\(index)" + String(repeating: "x", count: 3_000))
        }
        #expect(byteBounded.messages.count < GlobalNoticeStore.maximumCount)
        #expect(byteBounded.totalBytes <= GlobalNoticeStore.maximumTotalBytes)
    }

    @Test("replaceable progress coalesces and targeted removal preserves other notices")
    func keyedReplacementAndRemoval() {
        var store = GlobalNoticeStore()
        store.post("Package operation completed")
        store.post("Catching up one", replacing: .sessionCatchUp)
        store.post("Provider login completed")
        store.post("Catching up two", replacing: .sessionCatchUp)

        #expect(store.messages == [
            "Package operation completed",
            "Provider login completed",
            "Catching up two",
        ])

        store.remove(.sessionCatchUp)
        #expect(store.messages == [
            "Package operation completed",
            "Provider login completed",
        ])
    }

    @Test("consecutive duplicate unkeyed notices are coalesced")
    func duplicateCoalescing() {
        var store = GlobalNoticeStore()
        store.post("Connected")
        store.post("Connected")
        #expect(store.messages == ["Connected"])
    }
}
