import Testing
@testable import TronMobile

@Suite("Session selection reconciliation")
struct SessionSelectionPolicyTests {
    @Test("new empty sessions stay selected before Pi indexes their first message")
    func retainsLocallyCreatedUnindexedSession() {
        let selected = SessionSelectionPolicy.reconcile(
            selected: "new-empty",
            visibleIDs: ["older"],
            locallyCreatedUnindexedIDs: ["new-empty"]
        )
        #expect(selected == "new-empty")
    }

    @Test("dashboard discovery never mounts a fallback transcript")
    func clearsStaleSelectionWithoutFallback() {
        let selected = SessionSelectionPolicy.reconcile(
            selected: "deleted",
            visibleIDs: ["canonical"],
            locallyCreatedUnindexedIDs: []
        )
        #expect(selected == nil)
        #expect(SessionSelectionPolicy.reconcile(
            selected: nil,
            visibleIDs: ["canonical"],
            locallyCreatedUnindexedIDs: []
        ) == nil)
    }

    @Test("indexed selection remains stable")
    func retainsIndexedSelection() {
        let selected = SessionSelectionPolicy.reconcile(
            selected: "selected",
            visibleIDs: ["first", "selected"],
            locallyCreatedUnindexedIDs: []
        )
        #expect(selected == "selected")
    }
}
