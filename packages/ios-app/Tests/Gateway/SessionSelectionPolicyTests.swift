import Testing
@testable import TronMobile

@Suite("Session selection reconciliation")
struct SessionSelectionPolicyTests {
    @Test("new empty sessions stay selected before Pi indexes their first message")
    func retainsLocallyCreatedUnindexedSession() {
        let selected = SessionSelectionPolicy.reconcile(
            selected: "new-empty",
            visibleIDs: ["older"],
            locallyCreatedUnindexedIDs: ["new-empty"],
            firstVisibleID: "older"
        )
        #expect(selected == "new-empty")
    }

    @Test("stale selection falls back to canonical discovery")
    func replacesStaleSelection() {
        let selected = SessionSelectionPolicy.reconcile(
            selected: "deleted",
            visibleIDs: ["canonical"],
            locallyCreatedUnindexedIDs: [],
            firstVisibleID: "canonical"
        )
        #expect(selected == "canonical")
    }

    @Test("indexed selection remains stable")
    func retainsIndexedSelection() {
        let selected = SessionSelectionPolicy.reconcile(
            selected: "selected",
            visibleIDs: ["first", "selected"],
            locallyCreatedUnindexedIDs: [],
            firstVisibleID: "first"
        )
        #expect(selected == "selected")
    }
}
