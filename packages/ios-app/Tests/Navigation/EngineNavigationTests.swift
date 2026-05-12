import Testing
@testable import TronMobile

@Suite("Engine Navigation")
struct EngineNavigationTests {
    @Test("engine console is a first-class navigation mode")
    func engineModeExists() {
        #expect(NavigationMode.allCases.contains(.engine))
        #expect(NavigationMode.engine.rawValue == "Engine")
        #expect(NavigationMode.engine.icon == "server.rack")
    }
}
