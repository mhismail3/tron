import Testing
@testable import TronMobile

@Suite("Dashboard state ownership")
struct DashboardStateOwnerTests {
    @Test("a newer navigation intent rejects an older asynchronous completion")
    func navigationAdmission() {
        var owner = DashboardNavigationOwner()
        let importIntent = owner.begin()
        let newerIntent = owner.begin()

        let admittedImport = owner.admit(importIntent)
        let admittedNewer = owner.admit(newerIntent)
        let admittedDuplicate = owner.admit(newerIntent)
        #expect(!admittedImport)
        #expect(admittedNewer)
        #expect(!admittedDuplicate)
    }

    @Test("direct navigation invalidates pending asynchronous navigation")
    func navigationInvalidation() {
        var owner = DashboardNavigationOwner()
        let pending = owner.begin()
        owner.invalidate()
        let admitted = owner.admit(pending)
        #expect(!admitted)
    }

    @Test("only the latest catalog load may publish")
    func catalogAdmission() {
        var owner = SessionCatalogLoadOwner()
        let first = owner.begin()
        let second = owner.begin()
        #expect(!owner.admits(first))
        #expect(owner.admits(second))
        owner.invalidate()
        #expect(!owner.admits(second))
    }
}
