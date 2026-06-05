import Testing
@testable import TronMobile

@Suite("Engine Navigation")
struct EngineNavigationTests {
    @Test("work dashboard is the first-class non-chat navigation mode")
    func workModeExists() {
        #expect(NavigationMode.allCases.contains(.work))
        #expect(NavigationMode.allCases == [.agents, .work])
        #expect(NavigationMode.work.rawValue == "Work")
        #expect(NavigationMode.work.icon == "briefcase")
    }
}
