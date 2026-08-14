import Testing
@testable import TronMobile

@Suite("Presentation-owned transient state")
struct PresentationOwnedStoreTests {
    @Test("same-session generations retain independent disposable values")
    func generationIsolation() {
        struct Owner: Hashable {
            let sessionID: String
            let generation: Int
        }
        let first = Owner(sessionID: "session", generation: 1)
        let reopened = Owner(sessionID: "session", generation: 2)
        var store = PresentationOwnedStore<Owner, [String]>()

        store[first] = ["first draft"]
        store[reopened] = ["reopened draft"]
        store.removeValue(for: first)

        #expect(store[first] == nil)
        #expect(store[reopened] == ["reopened draft"])
    }

    @Test("different sessions cannot consume one another's transient values")
    func sessionIsolation() {
        let first = AppModel.SessionPresentationTarget(sessionID: "first", generation: 7)
        let second = AppModel.SessionPresentationTarget(sessionID: "second", generation: 7)
        var store = PresentationOwnedStore<AppModel.SessionPresentationTarget, String>()

        store[first] = "attachment"

        #expect(store[first] == "attachment")
        #expect(store[second] == nil)
    }
}
